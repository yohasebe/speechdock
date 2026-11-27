import XCTest
@testable import SpeechDock

/// In-memory keychain, so tests never touch the user's keychain.
private final class MemoryKeyStore: APIKeyStore {
    var items: [String: String] = [:]
    func retrieve(key: String) -> String? { items[key] }
    func save(key: String, value: String) throws { items[key] = value }
    func delete(key: String) throws { items[key] = nil }
}

/// Scripted op runner that records each call.
private final class FakeOpRunner: OpRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _inputs: [String] = []
    var handler: ([String], String) -> OpRunResult
    var delay: UInt64 = 0

    init(handler: @escaping ([String], String) -> OpRunResult) {
        self.handler = handler
    }

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var inputs: [String] {
        lock.lock(); defer { lock.unlock() }
        return _inputs
    }

    func run(executable: URL, arguments: [String], input: Data, timeout: TimeInterval) async -> OpRunResult {
        record(arguments, String(decoding: input, as: UTF8.self))
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return handler(arguments, String(decoding: input, as: UTF8.self))
    }

    private func record(_ arguments: [String], _ input: String) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(arguments)
        _inputs.append(input)
    }

    static func ok(_ text: String) -> OpRunResult {
        OpRunResult(status: 0, stdout: Data(text.utf8), stderr: Data(), timedOut: false)
    }

    static func fail(_ stderr: String) -> OpRunResult {
        OpRunResult(status: 1, stdout: Data(), stderr: Data(stderr.utf8), timedOut: false)
    }
}

/// Answers `op inject` by replacing known references, and `op read` for one.
private func syntheticOp(_ values: [String: String], injectError: String? = nil) -> ([String], String) -> OpRunResult {
    return { arguments, input in
        if arguments.first == "inject" {
            if let injectError { return FakeOpRunner.fail(injectError) }
            var output = input
            for (reference, value) in values {
                output = output.replacingOccurrences(of: "{{ \(reference) }}", with: value)
            }
            return output.contains("{{") ? FakeOpRunner.fail("[ERROR] isn't an item") : FakeOpRunner.ok(output)
        }
        if arguments.first == "read", let reference = arguments.last {
            if let value = values[reference] { return FakeOpRunner.ok(value) }
            return FakeOpRunner.fail("[ERROR] \"x\" isn't an item in the \"Test\" vault")
        }
        return FakeOpRunner.fail("unknown command")
    }
}

private let fakeOp = URL(fileURLWithPath: "/fake/op")
private let refA = "op://Test/FAKE_KEY/credential"
private let refB = "op://Test/OTHER_KEY/credential"

final class SecretReferenceTests: XCTestCase {

    // MARK: - Reference text

    func testReferenceShape() {
        XCTAssertTrue(SecretReference.isReference("op://Test/FAKE_KEY/credential"))
        XCTAssertTrue(SecretReference.isReference("  op://Test/FAKE_KEY/credential\n"))
        XCTAssertFalse(SecretReference.isReference("sk-not-a-reference"))

        XCTAssertTrue(SecretReference.isWellFormed("op://Test/FAKE_KEY/credential"))
        XCTAssertTrue(SecretReference.isWellFormed("op://Test/FAKE_KEY/section/credential"))
        XCTAssertFalse(SecretReference.isWellFormed("op://Test/FAKE_KEY"))
        XCTAssertFalse(SecretReference.isWellFormed("op://Test//credential"))
        XCTAssertFalse(SecretReference.isWellFormed("op://Test/FAKE KEY/credential"))
        XCTAssertFalse(SecretReference.isWellFormed("op://Test/{{x}}/credential"))
    }

    func testQuotedReferenceIsReadWithoutItsQuotes() async {
        for quoted in ["\"\(refA)\"", "'\(refA)'", "\u{201C}\(refA)\u{201D}", " \"\(refA)\"\n"] {
            XCTAssertEqual(SecretReference.normalized(quoted), refA)
            XCTAssertTrue(SecretReference.isReference(quoted))
            XCTAssertTrue(SecretReference.isWellFormed(quoted))
        }
        XCTAssertEqual(SecretReference.normalized("\"\(refA)"), "\"\(refA)", "an unmatched quote is kept")
        XCTAssertFalse(SecretReference.isWellFormed("\"\(refA)"))

        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a"]))
        let keys = manager(env: ["OPENAI_API_KEY": "\"\(refA)\""], runner: runner)
        let value = await keys.apiKey(for: .openAI)
        XCTAssertEqual(value, "fake-a")
        for input in runner.inputs { XCTAssertFalse(input.contains("\"")) }
    }

    func testFailureClassification() {
        func classify(_ text: String) -> SecretReferenceFailure {
            SecretReferenceFailure.classify(stderr: Data(text.utf8))
        }
        XCTAssertEqual(classify("[ERROR] You are not currently signed in."), .notSignedIn)
        XCTAssertEqual(classify("[ERROR] authorization prompt dismissed"), .cancelled)
        XCTAssertEqual(classify("[ERROR] \"x\" isn't an item in the \"Test\" vault"), .notFound)
        XCTAssertEqual(classify("something else"), .failed)
    }

    func testFailureMessagesDoNotRepeatReferences() {
        // Messages are fixed text: none carries a vault or item name. Only the
        // format hint for a malformed reference shows the generic form.
        for failure in [SecretReferenceFailure.opMissing, .notSignedIn, .cancelled, .notFound, .timeout, .failed, .malformed] {
            XCTAssertFalse(failure.localizedDescription.contains("FAKE_KEY"))
            XCTAssertEqual(failure.localizedDescription.contains("op://"), failure == .malformed)
        }
    }

    // MARK: - Resolver

    func testBatchReadUsesOneInject() async {
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a", refB: "fake-b"]))
        let resolver = SecretReferenceResolver(runner: runner, locateOp: { .success(fakeOp) })

        let a = await resolver.value(for: refA, batch: [refA, refB])
        XCTAssertEqual(try? a.get(), "fake-a")
        XCTAssertEqual(resolver.cachedValue(for: refB), "fake-b")
        XCTAssertEqual(runner.calls.map { $0.first }, ["inject"])

        // Cached: no further op calls.
        _ = await resolver.value(for: refB, batch: [refA, refB])
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testFailedInjectFallsBackToSingleReads() async {
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a"]))
        let resolver = SecretReferenceResolver(runner: runner, locateOp: { .success(fakeOp) })

        _ = await resolver.value(for: refA, batch: [refA, refB])
        XCTAssertEqual(resolver.cachedValue(for: refA), "fake-a")
        XCTAssertEqual(resolver.state(for: refB), .failed(.notFound))
        XCTAssertEqual(runner.calls.map { $0.first }, ["inject", "read", "read"])
    }

    func testCancelledApprovalIsNotAskedAgainUnlessForced() async {
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a"], injectError: "[ERROR] authorization prompt dismissed"))
        let resolver = SecretReferenceResolver(runner: runner, locateOp: { .success(fakeOp) })

        let first = await resolver.value(for: refA, batch: [refA, refB])
        XCTAssertEqual(first, .failure(.cancelled))
        XCTAssertEqual(runner.calls.count, 1, "a cancelled batch must not ask once per key")

        _ = await resolver.value(for: refA, batch: [refA])
        XCTAssertEqual(runner.calls.count, 1, "cancelled is not retried on its own")

        runner.handler = syntheticOp([refA: "fake-a"])
        let forced = await resolver.value(for: refA, batch: [refA], force: true)
        XCTAssertEqual(try? forced.get(), "fake-a")
    }

    func testOtherFailuresRetryAtMostOncePerInterval() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let runner = FakeOpRunner(handler: syntheticOp([:], injectError: "[ERROR] You are not currently signed in."))
        let resolver = SecretReferenceResolver(runner: runner, locateOp: { .success(fakeOp) }, now: { clock })

        _ = await resolver.value(for: refA, batch: [refA])
        _ = await resolver.value(for: refA, batch: [refA])
        XCTAssertEqual(runner.calls.count, 1)

        clock = clock.addingTimeInterval(SecretReferenceResolver.retryInterval)
        _ = await resolver.value(for: refA, batch: [refA])
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testMissingOpAndTimeout() async {
        let missing = SecretReferenceResolver(runner: FakeOpRunner(handler: syntheticOp([:])), locateOp: { .failure(.opMissing) })
        let none = await missing.value(for: refA, batch: [refA])
        XCTAssertEqual(none, .failure(.opMissing))

        let slow = FakeOpRunner { _, _ in OpRunResult(status: 15, stdout: Data(), stderr: Data(), timedOut: true) }
        let timing = SecretReferenceResolver(runner: slow, locateOp: { .success(fakeOp) })
        let timedOut = await timing.value(for: refA, batch: [refA])
        XCTAssertEqual(timedOut, .failure(.timeout))
    }

    func testConcurrentReadsStartOpOnce() async {
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a"]))
        runner.delay = 50_000_000
        let resolver = SecretReferenceResolver(runner: runner, locateOp: { .success(fakeOp) })

        async let first = resolver.value(for: refA, batch: [refA])
        async let second = resolver.value(for: refA, batch: [refA])
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { try? $0.get() }, ["fake-a", "fake-a"])
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testMalformedReferencesNeverReachOp() async {
        // A newline and braces would add a line to the inject template that
        // reads another item and shifts the K<n> mapping.
        let injected = "op://Test/FAKE_KEY/credential }}\nK0={{ op://Test/OTHER_KEY/credential"
        let braces = "op://Test/{{x}}/credential"
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a", refB: "fake-b"]))
        let resolver = SecretReferenceResolver(runner: runner, locateOp: { .success(fakeOp) })

        let result = await resolver.value(for: injected, batch: [injected, braces, refA])
        XCTAssertEqual(result, .failure(.malformed))
        XCTAssertEqual(resolver.state(for: braces), .failed(.malformed))
        XCTAssertEqual(resolver.cachedValue(for: refA), "fake-a")
        XCTAssertNil(resolver.cachedValue(for: refB), "the smuggled reference is never read")

        XCTAssertEqual(runner.calls.count, 1)
        for input in runner.inputs {
            XCTAssertFalse(input.contains("OTHER_KEY"))
            XCTAssertFalse(input.contains("{{x}}"))
            XCTAssertEqual(input.split(separator: "\n").count, 1, "one template line per well-formed reference")
        }

        let single = await resolver.readSingle(injected)
        XCTAssertEqual(single, .failure(.malformed))
        _ = await resolver.value(for: braces, batch: [braces])
        XCTAssertEqual(runner.calls.count, 1, "malformed references never start op, and are not retried")
    }

    func testMalformedEnvironmentReferenceIsUnusable() async {
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a"]))
        let keys = manager(env: ["OPENAI_API_KEY": "op://Test/FAKE_KEY}}\nK0={{ op://Test/OTHER_KEY/credential"],
                           runner: runner)
        let value = await keys.apiKey(for: .openAI)
        XCTAssertNil(value)
        XCTAssertEqual(keys.keyStatus(for: .openAI), .failed(.malformed))
        XCTAssertFalse(keys.unavailableReason(for: .openAI).contains("OTHER_KEY"))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testRejectedValueIsReadAgainOnce() async {
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a"]))
        let resolver = SecretReferenceResolver(runner: runner, locateOp: { .success(fakeOp) })
        _ = await resolver.value(for: refA, batch: [refA])

        XCTAssertTrue(resolver.providerRejected(refA))
        XCTAssertNil(resolver.cachedValue(for: refA))
        _ = await resolver.value(for: refA, batch: [refA])
        XCTAssertEqual(runner.calls.count, 2)

        XCTAssertFalse(resolver.providerRejected(refA), "only one re-read per reference")
        XCTAssertEqual(resolver.cachedValue(for: refA), "fake-a")
    }

    // MARK: - APIKeyManager

    private func manager(env: [String: String] = [:], store: MemoryKeyStore = MemoryKeyStore(),
                         runner: FakeOpRunner = FakeOpRunner(handler: syntheticOp([refA: "fake-a"]))) -> APIKeyManager {
        APIKeyManager(keychain: store, environment: { env }, testModeNoAPIKeys: false,
                      referenceResolver: SecretReferenceResolver(runner: runner, locateOp: { .success(fakeOp) }))
    }

    func testGrokUsesXAINameAndStillReadsGrokName() {
        XCTAssertEqual(STTProvider.grok.envKeyName, "XAI_API_KEY")
        XCTAssertEqual(TranslationProvider.grok.envKeyName, "XAI_API_KEY")
        XCTAssertEqual(RealtimeSTTProvider.grok.envKeyName, "XAI_API_KEY")
        XCTAssertEqual(TTSProvider.grok.envKeyName, "XAI_API_KEY")
        XCTAssertEqual(APIKeyManager.canonicalName("GROK_API_KEY"), "XAI_API_KEY")
        XCTAssertEqual(APIKeyManager.candidateNames("GROK_API_KEY"), ["XAI_API_KEY", "GROK_API_KEY"])
        XCTAssertEqual(APIKeyManager.candidateNames("OPENAI_API_KEY"), ["OPENAI_API_KEY"])
    }

    func testGrokLookupOrder() {
        let store = MemoryKeyStore()
        store.items = ["XAI_API_KEY": "kc-xai", "GROK_API_KEY": "kc-grok"]
        XCTAssertEqual(manager(env: ["XAI_API_KEY": "env-xai", "GROK_API_KEY": "env-grok"], store: store).getAPIKey(for: .grok), "env-xai")
        XCTAssertEqual(manager(env: ["GROK_API_KEY": "env-grok"], store: store).getAPIKey(for: .grok), "env-grok")
        XCTAssertEqual(manager(store: store).getAPIKey(for: .grok), "kc-xai")

        let legacyOnly = MemoryKeyStore()
        legacyOnly.items = ["GROK_API_KEY": "kc-grok"]
        let legacy = manager(store: legacyOnly)
        XCTAssertEqual(legacy.getAPIKey(for: .grok), "kc-grok")
        XCTAssertEqual(legacy.getAPIKey(for: "GROK_API_KEY"), "kc-grok")
        XCTAssertEqual(legacy.keyOrigin(for: .grok)?.isLegacyName, true)
        XCTAssertEqual(legacyOnly.items["GROK_API_KEY"], "kc-grok", "reading never moves the item")
    }

    func testSavingGrokMovesToXAIOnlyWhenSaved() throws {
        let store = MemoryKeyStore()
        store.items = ["GROK_API_KEY": "old"]
        let keys = manager(store: store)
        try keys.setAPIKey("new", for: .grok)
        XCTAssertEqual(store.items, ["XAI_API_KEY": "new"])

        store.items["GROK_API_KEY"] = "old"
        try keys.deleteAPIKey(for: .grok)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testReferenceIsNeverReturnedAsAKey() async {
        let store = MemoryKeyStore()
        store.items = ["OPENAI_API_KEY": refA]
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a"]))
        let keys = manager(store: store, runner: runner)

        XCTAssertNil(keys.getAPIKey(for: .openAI), "unread reference counts as no key")
        XCTAssertEqual(keys.keyStatus(for: .openAI), .pending)
        XCTAssertTrue(keys.hasAPIKey(for: .openAI))
        XCTAssertTrue(runner.calls.isEmpty, "synchronous checks never start op")

        let value = await keys.apiKey(for: .openAI)
        XCTAssertEqual(value, "fake-a")
        XCTAssertEqual(keys.getAPIKey(for: .openAI), "fake-a")
        XCTAssertEqual(store.items["OPENAI_API_KEY"], refA, "only the reference is stored")
        XCTAssertEqual(keys.storedKeychainValue(for: .openAI), refA)
    }

    func testEnvironmentReferenceAndBatching() async {
        let store = MemoryKeyStore()
        store.items = ["GEMINI_API_KEY": refB]
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a", refB: "fake-b"]))
        let keys = manager(env: ["OPENAI_API_KEY": refA], store: store, runner: runner)

        let value = await keys.apiKey(for: .openAI)
        XCTAssertEqual(value, "fake-a")
        XCTAssertEqual(keys.getAPIKey(for: .gemini), "fake-b", "the first read takes every reference")
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testUnreadableReferenceReportsReasonOnly() async {
        let store = MemoryKeyStore()
        store.items = ["OPENAI_API_KEY": refB]
        let keys = manager(store: store, runner: FakeOpRunner(handler: syntheticOp([:])))

        let value = await keys.apiKey(for: .openAI)
        XCTAssertNil(value)
        XCTAssertEqual(keys.keyStatus(for: .openAI), .failed(.notFound))
        XCTAssertFalse(keys.hasAPIKey(for: .openAI))
        let reason = keys.unavailableReason(for: .openAI)
        XCTAssertFalse(reason.contains("op://"))
        XCTAssertFalse(reason.contains("OTHER_KEY"))
    }

    func testRejectionDropsCachedValueOnce() async {
        let store = MemoryKeyStore()
        store.items = ["XAI_API_KEY": refA]
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a"]))
        let keys = manager(store: store, runner: runner)
        _ = await keys.apiKey(for: .grok)

        keys.noteResponse(statusCode: 500, providerName: "Grok TTS")
        XCTAssertEqual(keys.getAPIKey(for: .grok), "fake-a")
        keys.noteResponse(statusCode: 401, providerName: "Grok TTS")
        XCTAssertNil(keys.getAPIKey(for: .grok))
        _ = await keys.apiKey(for: .grok)
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testTestModeHasNoKeysAndReadsNothing() async {
        let store = MemoryKeyStore()
        store.items = ["OPENAI_API_KEY": refA]
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a"]))
        let keys = APIKeyManager(keychain: store, environment: { [:] }, testModeNoAPIKeys: true,
                                 referenceResolver: SecretReferenceResolver(runner: runner, locateOp: { .success(fakeOp) }))
        let value = await keys.apiKey(for: .openAI)
        XCTAssertNil(value)
        XCTAssertEqual(keys.keyStatus(for: .openAI), .notSet)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testValidatorNeverSendsAReference() async {
        let result = await APIKeyValidator.validate(key: refA, for: .openAI)
        guard case .invalid = result else {
            return XCTFail("a reference must be refused before any request")
        }
    }

    // MARK: - Real process with a synthetic op

    #if DEBUG
    func testProcessRunnerWithSyntheticOp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("speechdock-op-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("op")
        try """
        #!/bin/sh
        if [ "$1" = inject ]; then
          input=$(cat)
          case "$input" in *op://Test/MISSING*) echo '[ERROR] "MISSING" isn'"'"'t an item' >&2; exit 1;; esac
          printf '%s\\n' "$input" | sed 's#{{ op://Test/FAKE_KEY/credential }}#fake-value-123#'
          exit 0
        fi
        if [ "$1" = read ] && [ "$3" = op://Test/FAKE_KEY/credential ]; then printf 'fake-value-123'; exit 0; fi
        echo '[ERROR] "MISSING" isn'"'"'t an item' >&2
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let located = OpLocator.trustedOp(environment: ["SPEECHDOCK_OP_CLI": script.path])
        XCTAssertEqual(try? located.get().path, script.path)
        let resolver = SecretReferenceResolver(runner: ProcessOpRunner(), locateOp: { located })

        let batch = await resolver.value(for: refA, batch: [refA])
        XCTAssertEqual(try? batch.get(), "fake-value-123")
        let single = await SecretReferenceResolver(runner: ProcessOpRunner(), locateOp: { located }).readSingle(refA)
        XCTAssertEqual(try? single.get(), "fake-value-123")
        let missing = await resolver.value(for: "op://Test/MISSING/credential", batch: [])
        XCTAssertEqual(missing, .failure(.notFound))
    }
    #endif

    func testUntrustedOpIsNotRun() async {
        let runner = FakeOpRunner(handler: syntheticOp([refA: "fake-a"]))
        let resolver = SecretReferenceResolver(runner: runner, locateOp: { .failure(.opUntrusted) })
        let result = await resolver.value(for: refA, batch: [refA])
        XCTAssertEqual(result, .failure(.opUntrusted))
        let single = await resolver.readSingle(refA)
        XCTAssertEqual(single, .failure(.opUntrusted))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testSignatureRequirement() throws {
        // A system binary is validly signed but is not 1Password's op.
        XCTAssertFalse(OpLocator.isTrusted(URL(fileURLWithPath: "/bin/ls")))
        XCTAssertFalse(OpLocator.isTrusted(URL(fileURLWithPath: "/nonexistent/op")))
        // The requirement itself is accepted by Security and matches its own subject.
        XCTAssertTrue(OpLocator.isTrusted(URL(fileURLWithPath: "/bin/ls"),
                                          requirementText: #"identifier "com.apple.ls" and anchor apple"#))

        let installed = URL(fileURLWithPath: "/opt/homebrew/bin/op")
        guard FileManager.default.isExecutableFile(atPath: installed.path) else {
            throw XCTSkip("1Password CLI is not installed here")
        }
        XCTAssertTrue(OpLocator.isTrusted(installed.resolvingSymlinksInPath()))
    }

    func testLocatorSearchesHomebrewPaths() {
        let found = OpLocator.locate(environment: ["PATH": "/usr/bin:/bin"],
                                     isExecutable: { $0 == "/opt/homebrew/bin/op" })
        XCTAssertEqual(found?.path, "/opt/homebrew/bin/op")
        XCTAssertNil(OpLocator.locate(environment: ["PATH": "/usr/bin"], isExecutable: { _ in false }))
    }
}

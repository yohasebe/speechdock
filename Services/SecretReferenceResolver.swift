import Foundation
import Security

/// 1Password secret references (`op://vault/item/field`) that may stand in
/// for an API key, in the keychain or in an environment variable.
enum SecretReference {
    static let prefix = "op://"

    /// The reference without surrounding whitespace or one pair of enclosing
    /// quotes, which 1Password's "Copy Secret Reference" includes.
    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}")]
        where trimmed.count >= 2 && trimmed.hasPrefix(open) && trimmed.hasSuffix(close) {
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    static func isReference(_ value: String) -> Bool {
        normalized(value).hasPrefix(prefix)
    }

    /// `op://vault/item/field` or `op://vault/item/section/field`. Whitespace
    /// and braces are rejected: the reference goes into an `op inject` template.
    static func isWellFormed(_ value: String) -> Bool {
        let trimmed = normalized(value)
        guard trimmed.hasPrefix(prefix) else { return false }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "{" || $0 == "}" }) {
            return false
        }
        let parts = trimmed.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        return (3...4).contains(parts.count) && parts.allSatisfy { !$0.isEmpty }
    }
}

/// Why a reference could not be read. Only this code is shown or logged:
/// the reference names a vault and an item, and op's own messages can repeat it.
enum SecretReferenceFailure: String, Error, Equatable, Sendable {
    case opMissing
    case notSignedIn
    case cancelled
    case notFound
    case timeout
    case failed
    /// Not of the form op://vault/item/field; never passed to op.
    case malformed
    /// An op was found but is not signed by 1Password; it is not run.
    case opUntrusted

    var localizedDescription: String {
        switch self {
        case .opMissing:
            return NSLocalizedString("1Password CLI (op) was not found", comment: "1Password reference failure")
        case .notSignedIn:
            return NSLocalizedString("1Password CLI is not signed in", comment: "1Password reference failure")
        case .cancelled:
            return NSLocalizedString("1Password access was not approved", comment: "1Password reference failure")
        case .notFound:
            return NSLocalizedString("1Password item was not found", comment: "1Password reference failure")
        case .timeout:
            return NSLocalizedString("1Password did not respond in time", comment: "1Password reference failure")
        case .failed:
            return NSLocalizedString("1Password reference could not be read", comment: "1Password reference failure")
        case .malformed:
            return NSLocalizedString("Use the form op://vault/item/field", comment: "1Password reference format")
        case .opUntrusted:
            return NSLocalizedString("1Password CLI (op) could not be verified", comment: "1Password reference failure")
        }
    }

    /// A reason code for a failed op call, from its standard error.
    static func classify(stderr: Data) -> SecretReferenceFailure {
        let text = String(decoding: stderr, as: UTF8.self).lowercased()
        let patterns: [(SecretReferenceFailure, String)] = [
            (.notSignedIn, #"not (currently )?signed in|sign in|session expired|no accounts|locked"#),
            (.cancelled, #"dismiss|cancel|denied|authorization"#),
            (.notFound, #"isn't (an item|a vault|a field)|not found|could not find|no item|invalid secret reference|invalid reference"#)
        ]
        for (failure, pattern) in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return failure
        }
        return .failed
    }
}

struct OpRunResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
}

/// Runs the op CLI. Replaced in tests.
protocol OpRunning: Sendable {
    func run(executable: URL, arguments: [String], input: Data, timeout: TimeInterval) async -> OpRunResult
}

/// Runs op directly (no shell), with the template on stdin. The result is
/// kept in memory only.
///
/// op is spawned as its own responsible process. A child of SpeechDock would
/// otherwise be held to SpeechDock's privacy permissions: reading the
/// 1Password app's group container (where the CLI integration lives) counts
/// as another developer's app data, which macOS denies without asking, and op
/// then reports that it is not signed in. Disclaiming makes op (signed by
/// 1Password) responsible for its own access, as it is when run from a
/// terminal. The disclaim call is private API; when it cannot be found, op
/// is spawned without it and may report not signed in.
struct ProcessOpRunner: OpRunning {
    func run(executable: URL, arguments: [String], input: Data, timeout: TimeInterval) async -> OpRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runBlocking(executable: executable, arguments: arguments,
                                                                input: input, timeout: timeout))
            }
        }
    }

    private typealias DisclaimFunction = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static let disclaim: DisclaimFunction? = {
        // RTLD_DEFAULT is (void *)-2 on Darwin.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        return unsafeBitCast(symbol, to: DisclaimFunction.self)
    }()

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()
        var timedOut = false
    }

    private static func failure() -> OpRunResult {
        OpRunResult(status: -1, stdout: Data(), stderr: Data(), timedOut: false)
    }

    private static func runBlocking(executable: URL, arguments: [String], input: Data, timeout: TimeInterval) -> OpRunResult {
        var stdinPipe: [Int32] = [-1, -1], stdoutPipe: [Int32] = [-1, -1], stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0 else { return failure() }
        guard pipe(&stdoutPipe) == 0 else {
            stdinPipe.forEach { close($0) }
            return failure()
        }
        guard pipe(&stderrPipe) == 0 else {
            (stdinPipe + stdoutPipe).forEach { close($0) }
            return failure()
        }
        // No other child the app starts meanwhile may inherit these ends; one
        // holding the write end of stdin would keep op waiting for its end.
        // The child's own copies come from the dup2 actions below.
        for fd in stdinPipe + stdoutPipe + stderrPipe {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        // Writing after op has exited must not raise SIGPIPE in the app.
        _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach op.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        if let disclaim {
            _ = disclaim(&attributes, 1)
        }

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        // The child holds its own copies now.
        [stdinPipe[0], stdoutPipe[1], stderrPipe[1]].forEach { close($0) }
        guard spawned == 0 else {
            [stdinPipe[1], stdoutPipe[0], stderrPipe[0]].forEach { close($0) }
            return failure()
        }

        let box = Box()
        let readers = DispatchGroup()
        for (fd, isStdout) in [(stdoutPipe[0], true), (stderrPipe[0], false)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                let data = handle.readDataToEndOfFile()
                box.lock.lock()
                if isStdout { box.stdout = data } else { box.stderr = data }
                box.lock.unlock()
                readers.leave()
            }
        }

        let writer = FileHandle(fileDescriptor: stdinPipe[1], closeOnDealloc: true)
        try? writer.write(contentsOf: input)
        try? writer.close()

        let timer = DispatchWorkItem {
            box.lock.lock(); box.timedOut = true; box.lock.unlock()
            kill(pid, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        timer.cancel()
        readers.wait()

        // WIFEXITED / WEXITSTATUS (macros are not available in Swift).
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        box.lock.lock(); defer { box.lock.unlock() }
        return OpRunResult(status: exitCode, stdout: box.stdout, stderr: box.stderr, timedOut: box.timedOut)
    }
}

enum OpLocator {
    /// op's own designated requirement (1Password CLI, Developer ID, team
    /// 2BUA8C4S2C). Only an executable that meets it is run.
    static let requirement = #"identifier "com.1password.op" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "2BUA8C4S2C""#

    /// The op to run: found, with symbolic links resolved, and verified.
    static func trustedOp(environment: [String: String] = ProcessInfo.processInfo.environment) -> Result<URL, SecretReferenceFailure> {
        #if DEBUG
        // Tests and debug builds may name a synthetic op; it is not verified.
        if let override = environment["SPEECHDOCK_OP_CLI"], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override)
                ? .success(URL(fileURLWithPath: override)) : .failure(.opMissing)
        }
        #endif
        guard let found = locate(environment: environment) else { return .failure(.opMissing) }
        let resolved = found.resolvingSymlinksInPath()
        return isTrusted(resolved) ? .success(resolved) : .failure(.opUntrusted)
    }

    /// Whether the executable at `url` meets op's designated requirement.
    static func isTrusted(_ url: URL, requirementText: String = requirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    /// A GUI app does not inherit the login shell's PATH, so the usual
    /// install locations are tried as well.
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin"]
        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent("op")
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}

/// Reads references with the op CLI and keeps the results in this process's
/// memory until it quits. Results are never written to the keychain,
/// defaults, files or logs, and neither is the reference text.
///
/// Reads are batched: the first read gathers every reference the app knows
/// and reads them with one `op inject`, so 1Password asks at most once.
final class SecretReferenceResolver: @unchecked Sendable {
    enum State: Equatable {
        case resolved(String)
        case failed(SecretReferenceFailure)
    }

    static let opTimeout: TimeInterval = 120  // leaves time to answer a Touch ID prompt
    /// A failed read (other than a cancelled approval) is tried again on a
    /// later use, but not more often than this: subtitle translation asks
    /// for the key once per sentence.
    static let retryInterval: TimeInterval = 60

    private let runner: OpRunning
    private let locateOp: () -> Result<URL, SecretReferenceFailure>
    private let onChange: @Sendable () -> Void
    private let now: () -> Date

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private var failedAt: [String: Date] = [:]
    /// References already read again after the provider rejected their value.
    private var rereadAfterRejection: Set<String> = []
    private var inFlight: Task<Void, Never>?

    init(runner: OpRunning = ProcessOpRunner(),
         locateOp: @escaping () -> Result<URL, SecretReferenceFailure> = { OpLocator.trustedOp() },
         onChange: @escaping @Sendable () -> Void = {},
         now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.locateOp = locateOp
        self.onChange = onChange
        self.now = now
    }

    // MARK: - Synchronous reads (never start op)

    func state(for reference: String) -> State? {
        lock.lock(); defer { lock.unlock() }
        return states[Self.key(reference)]
    }

    func cachedValue(for reference: String) -> String? {
        if case .resolved(let value) = state(for: reference) { return value }
        return nil
    }

    // MARK: - Reading

    /// The value for `reference`, reading every reference in `batch` first
    /// when it is not known yet. A reference whose approval was cancelled is
    /// not asked again unless `force` is set.
    func value(for reference: String, batch: [String], force: Bool = false) async -> Result<String, SecretReferenceFailure> {
        let key = Self.key(reference)
        let (current, failedTime) = snapshot(key)
        if let current, !needsRead(current, failedAt: failedTime, force: force) {
            return Self.result(of: current)
        }
        await read(Set(batch.map(Self.key)).union([key]), force: force)
        return state(for: key).map(Self.result(of:)) ?? .failure(.failed)
    }

    /// Reads every reference that is not read yet (settings opened, reload).
    func prepare(_ references: [String], force: Bool = false) async {
        await read(Set(references.map(Self.key)), force: force)
    }

    /// Reads one reference on its own with `op read` (saving in Settings).
    /// The value is cached on success, so using it does not ask again.
    func readSingle(_ reference: String) async -> Result<String, SecretReferenceFailure> {
        let key = Self.key(reference)
        guard SecretReference.isWellFormed(key) else {
            store([key: .failed(.malformed)])
            return .failure(.malformed)
        }
        let op: URL
        switch locateOp() {
        case .success(let url): op = url
        case .failure(let failure): return .failure(failure)
        }
        let state = await readOne(key, op: op)
        store([key: state])
        return Self.result(of: state)
    }

    /// The provider rejected the value read from `reference` (HTTP 401/403).
    /// The cached value is dropped once, so the next use reads it again;
    /// returns whether it was dropped.
    @discardableResult
    func providerRejected(_ reference: String) -> Bool {
        let key = Self.key(reference)
        lock.lock()
        guard case .resolved = states[key], !rereadAfterRejection.contains(key) else {
            lock.unlock()
            return false
        }
        states[key] = nil
        rereadAfterRejection.insert(key)
        lock.unlock()
        onChange()
        return true
    }

    /// Forget results for `reference` (a new reference was saved, or the user reloads).
    func forget(_ reference: String) {
        let key = Self.key(reference)
        lock.lock()
        states[key] = nil
        failedAt[key] = nil
        rereadAfterRejection.remove(key)
        lock.unlock()
        onChange()
    }

    // MARK: - Internals

    private static func key(_ reference: String) -> String {
        SecretReference.normalized(reference)
    }

    private static func result(of state: State) -> Result<String, SecretReferenceFailure> {
        switch state {
        case .resolved(let value): return .success(value)
        case .failed(let failure): return .failure(failure)
        }
    }

    private func snapshot(_ key: String) -> (State?, Date?) {
        lock.lock(); defer { lock.unlock() }
        return (states[key], failedAt[key])
    }

    /// Resolved values and cancelled approvals stay; other failures are read
    /// again on a later use, at most once per retryInterval.
    private func needsRead(_ state: State, failedAt: Date?, force: Bool) -> Bool {
        switch state {
        case .resolved: return false
        case .failed(.cancelled), .failed(.malformed): return force
        case .failed:
            if force { return true }
            guard let failedAt else { return true }
            return now().timeIntervalSince(failedAt) >= Self.retryInterval
        }
    }

    private enum ReadStep {
        case wait(Task<Void, Never>)
        case run(Task<Void, Never>)
        case done
    }

    /// One read at a time; a read that starts while another runs waits for
    /// it and then reads whatever is still missing. Checking and starting
    /// happen under one lock, so two callers never start op twice.
    private func read(_ keys: Set<String>, force: Bool) async {
        while true {
            switch nextReadStep(keys, force: force) {
            case .wait(let running):
                await running.value
            case .run(let task):
                await task.value
                return
            case .done:
                return
            }
        }
    }

    private func nextReadStep(_ keys: Set<String>, force: Bool) -> ReadStep {
        lock.lock(); defer { lock.unlock() }
        if let running = inFlight { return .wait(running) }
        let missing = keys.filter { key in
            guard let state = states[key] else { return true }
            return needsRead(state, failedAt: failedAt[key], force: force)
        }
        if missing.isEmpty { return .done }
        // The task clears inFlight itself; it cannot get the lock before
        // this function has stored it.
        let task = Task {
            await self.readBatch(missing.sorted())
            self.clearInFlight()
        }
        inFlight = task
        return .run(task)
    }

    private func clearInFlight() {
        lock.lock(); defer { lock.unlock() }
        inFlight = nil
    }

    private func readBatch(_ candidates: [String]) async {
        // Only well-formed references reach op. A newline or braces in a
        // reference from the environment or the keychain would otherwise add
        // lines to the inject template (reading another reference, or
        // shifting the K<n> mapping).
        let malformed = candidates.filter { !SecretReference.isWellFormed($0) }
        if !malformed.isEmpty {
            store(Dictionary(uniqueKeysWithValues: malformed.map { ($0, State.failed(.malformed)) }))
        }
        let keys = candidates.filter { SecretReference.isWellFormed($0) }
        guard !keys.isEmpty else { return }
        let op: URL
        switch locateOp() {
        case .success(let url): op = url
        case .failure(let failure):
            store(Dictionary(uniqueKeysWithValues: keys.map { ($0, State.failed(failure)) }))
            return
        }

        // Template lines are keyed by index, so the output maps back without
        // repeating the reference.
        let template = keys.enumerated().map { "K\($0.offset)={{ \($0.element) }}\n" }.joined()
        let all = await runner.run(executable: op, arguments: ["inject"], input: Data(template.utf8),
                                   timeout: Self.opTimeout)
        if all.status == 0 && !all.timedOut {
            var found: [String: State] = [:]
            for line in String(decoding: all.stdout, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
                guard let eq = line.firstIndex(of: "="), line.hasPrefix("K"),
                      let index = Int(line[line.index(after: line.startIndex)..<eq]), keys.indices.contains(index) else { continue }
                var value = String(line[line.index(after: eq)...])
                if value.hasSuffix("\r") { value.removeLast() }
                if !value.isEmpty { found[keys[index]] = .resolved(value) }
            }
            for key in keys where found[key] == nil { found[key] = .failed(.failed) }
            store(found)
            return
        }
        if all.timedOut {
            store(Dictionary(uniqueKeysWithValues: keys.map { ($0, State.failed(.timeout)) }))
            return
        }
        // inject fails as a whole when any reference fails; read each on its
        // own to tell which failed and why. A cancelled approval stops here
        // rather than asking once per key.
        let batchFailure = SecretReferenceFailure.classify(stderr: all.stderr)
        if batchFailure == .cancelled || batchFailure == .notSignedIn {
            store(Dictionary(uniqueKeysWithValues: keys.map { ($0, State.failed(batchFailure)) }))
            return
        }
        var results: [String: State] = [:]
        for key in keys {
            results[key] = await readOne(key, op: op)
        }
        store(results)
    }

    private func readOne(_ key: String, op: URL) async -> State {
        let one = await runner.run(executable: op, arguments: ["read", "--no-newline", key], input: Data(),
                                   timeout: Self.opTimeout)
        if one.timedOut { return .failed(.timeout) }
        if one.status == 0, !one.stdout.isEmpty {
            return .resolved(String(decoding: one.stdout, as: UTF8.self))
        }
        return .failed(SecretReferenceFailure.classify(stderr: one.stderr))
    }

    private func store(_ results: [String: State]) {
        lock.lock()
        let stamp = now()
        for (key, state) in results {
            states[key] = state
            if case .failed = state { failedAt[key] = stamp } else { failedAt[key] = nil }
        }
        lock.unlock()
        onChange()
    }
}

import XCTest
@testable import SpeechDock

/// A voice request that records its key and completes when the test says so.
@MainActor
private final class HeldRequests {
    var keys: [String] = []
    private var pending: [CheckedContinuation<[TTSVoice]?, Never>?] = []

    func request(_ key: String) async -> [TTSVoice]? {
        keys.append(key)
        return await withCheckedContinuation { pending.append($0) }
    }

    func complete(_ index: Int, with voices: [TTSVoice]?) {
        guard index < pending.count, let continuation = pending[index] else {
            return XCTFail("request \(index) is not waiting (made: \(keys))")
        }
        pending[index] = nil
        continuation.resume(returning: voices)
    }

    /// Ends every request still waiting, so a failed test does not hang.
    func completeAll() {
        for index in pending.indices where pending[index] != nil { complete(index, with: nil) }
    }
}

/// Drives the real VoiceFetchCoordinator with held requests.
@MainActor
final class VoiceFetchCoordinatorTests: XCTestCase {
    private var requests: HeldRequests!
    private var stored: [[TTSVoice]] = []
    private var coordinator: VoiceFetchCoordinator!

    override func setUp() async throws {
        requests = HeldRequests()
        stored = []
        coordinator = VoiceFetchCoordinator(
            request: { [weak self] key in await self?.requests.request(key) ?? nil },
            store: { [weak self] in self?.stored.append($0) })
    }

    override func tearDown() async throws {
        requests.completeAll()
    }

    private func voice(_ id: String) -> TTSVoice {
        TTSVoice(id: id, name: id, language: "", isDefault: true)
    }

    private func start(_ key: String) -> Task<Void, Never> {
        Task { await coordinator.fetch(apiKey: key) }
    }

    /// Waits until `count` requests have been made; false (after failing) if
    /// another number was made, and the test then stops, leaving tearDown to
    /// end the held requests. Callers that join a request make none, so they
    /// are given the same turns to reach it.
    private func waitForRequests(_ count: Int) async -> Bool {
        for _ in 0..<1000 where requests.keys.count < count { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(requests.keys.count, count, "requests made: \(requests.keys)")
        return requests.keys.count == count
    }

    private var storedIDs: [[String]] { stored.map { $0.map(\.id) } }

    func testSameKeySharesOneRequest() async {
        let callers = (0..<3).map { _ in start("A") }
        guard await waitForRequests(1) else { return }
        requests.complete(0, with: [voice("a")])
        for caller in callers { await caller.value }
        XCTAssertEqual(storedIDs, [["a"]])
    }

    func testNewKeyIsNotMergedIntoOldRequestAndOldResultIsDropped() async {
        let old = start("A")
        guard await waitForRequests(1) else { return }
        let new = start("B")
        guard await waitForRequests(2) else { return }
        XCTAssertEqual(requests.keys, ["A", "B"])
        requests.complete(1, with: [voice("b")])
        await new.value
        requests.complete(0, with: [voice("a")])
        await old.value
        XCTAssertEqual(storedIDs, [["b"]], "the replaced key's late response is not stored")
    }

    func testReturningToAKeyJoinsItsRequestInProgress() async {
        let first = start("A")
        guard await waitForRequests(1) else { return }
        let other = start("B")
        guard await waitForRequests(2) else { return }
        let again = start("A")
        guard await waitForRequests(2) else { return }
        XCTAssertEqual(requests.keys, ["A", "B"], "A is not requested twice")
        requests.complete(1, with: [voice("b")])
        await other.value
        requests.complete(0, with: [voice("a")])
        await first.value
        await again.value
        XCTAssertEqual(storedIDs, [["a"]], "only the current key's result, once")
    }

    func testFailedRequestCanBeRetried() async {
        let first = start("A")
        guard await waitForRequests(1) else { return }
        requests.complete(0, with: nil)
        await first.value
        XCTAssertTrue(stored.isEmpty)

        let retry = start("A")
        guard await waitForRequests(2) else { return }
        XCTAssertEqual(requests.keys, ["A", "A"])
        requests.complete(1, with: [voice("a")])
        await retry.value
        XCTAssertEqual(stored.count, 1)
    }
}

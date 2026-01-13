import XCTest
@testable import TypeTalk

final class KeychainServiceTests: XCTestCase {
    private var keychainService: KeychainService!
    private let testKey = "test_api_key_\(UUID().uuidString)"

    override func setUpWithError() throws {
        keychainService = KeychainService()
        // Clean up any existing test key
        try? keychainService.delete(key: testKey)
    }

    override func tearDownWithError() throws {
        // Clean up test key
        try? keychainService.delete(key: testKey)
        keychainService = nil
    }

    func testSaveAndRetrieve() throws {
        let testValue = "sk-test-api-key-12345"

        // Save
        try keychainService.save(key: testKey, value: testValue)

        // Retrieve
        let retrieved = keychainService.retrieve(key: testKey)

        XCTAssertEqual(retrieved, testValue, "Retrieved value should match saved value")
    }

    func testRetrieveNonExistent() {
        let nonExistentKey = "non_existent_key_\(UUID().uuidString)"
        let result = keychainService.retrieve(key: nonExistentKey)

        XCTAssertNil(result, "Retrieving non-existent key should return nil")
    }

    func testDelete() throws {
        let testValue = "temporary-value"

        // Save first
        try keychainService.save(key: testKey, value: testValue)

        // Verify it exists
        XCTAssertNotNil(keychainService.retrieve(key: testKey))

        // Delete
        try keychainService.delete(key: testKey)

        // Verify it's gone
        XCTAssertNil(keychainService.retrieve(key: testKey), "Key should be deleted")
    }

    func testOverwrite() throws {
        let firstValue = "first-value"
        let secondValue = "second-value"

        // Save first value
        try keychainService.save(key: testKey, value: firstValue)
        XCTAssertEqual(keychainService.retrieve(key: testKey), firstValue)

        // Overwrite with second value
        try keychainService.save(key: testKey, value: secondValue)
        XCTAssertEqual(keychainService.retrieve(key: testKey), secondValue, "Value should be overwritten")
    }

    func testEmptyValue() throws {
        let emptyValue = ""

        try keychainService.save(key: testKey, value: emptyValue)
        let retrieved = keychainService.retrieve(key: testKey)

        XCTAssertEqual(retrieved, emptyValue, "Empty string should be saved and retrieved correctly")
    }

    func testUnicodeValue() throws {
        let unicodeValue = "APIキー-日本語テスト-🔐"

        try keychainService.save(key: testKey, value: unicodeValue)
        let retrieved = keychainService.retrieve(key: testKey)

        XCTAssertEqual(retrieved, unicodeValue, "Unicode characters should be preserved")
    }

    func testConcurrentAccess() throws {
        let iterations = 100
        let expectation = XCTestExpectation(description: "Concurrent access")
        expectation.expectedFulfillmentCount = iterations

        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for i in 0..<iterations {
            queue.async {
                let key = "\(self.testKey)_\(i)"
                let value = "value_\(i)"

                do {
                    try self.keychainService.save(key: key, value: value)
                    let retrieved = self.keychainService.retrieve(key: key)
                    XCTAssertEqual(retrieved, value)
                    try? self.keychainService.delete(key: key)
                } catch {
                    XCTFail("Concurrent access failed: \(error)")
                }

                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 30.0)
    }
}

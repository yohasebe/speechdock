import Foundation

/// Facts about the process the app is running in.
enum RuntimeContext {
    /// True inside the unit-test host, which shares the app's bundle ID and keychain items.
    static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

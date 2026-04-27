import Foundation
import os.log

#if DEBUG
private let speechDockDebugLog = OSLog(subsystem: "com.speechdock.app.dev", category: "debug")
#endif

/// Debug-only print function. Completely eliminated in release builds.
/// Use instead of print() to prevent log output in production.
@inline(__always)
func dprint(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    Swift.print(output, terminator: terminator)
    // Also log to unified logging so `log stream --predicate 'subsystem == "com.speechdock.app.dev"'` works.
    os_log("%{public}@", log: speechDockDebugLog, type: .debug, output)
    #endif
}

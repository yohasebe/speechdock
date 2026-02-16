import Foundation

/// Debug-only print function. Completely eliminated in release builds.
/// Use instead of print() to prevent log output in production.
@inline(__always)
func dprint(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    Swift.print(output, terminator: terminator)
    #endif
}

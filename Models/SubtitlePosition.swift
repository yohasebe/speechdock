import Foundation

/// Position for subtitle overlay display
enum SubtitlePosition: String, Codable, CaseIterable, Identifiable {
    case top
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }

    var localizedName: String {
        switch self {
        case .top: return NSLocalizedString("Top", comment: "Subtitle position top")
        case .bottom: return NSLocalizedString("Bottom", comment: "Subtitle position bottom")
        }
    }
}

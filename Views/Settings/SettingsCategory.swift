import SwiftUI

/// Categories for the unified settings sidebar
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case speechToText
    case textToSpeech
    case translation
    case subtitle
    case shortcuts
    case textReplacement
    case appearance
    case apiKeys
    case about

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speechToText: return NSLocalizedString("Speech-to-Text", comment: "Settings category")
        case .textToSpeech: return NSLocalizedString("Text-to-Speech", comment: "Settings category")
        case .translation: return NSLocalizedString("Translation", comment: "Settings category")
        case .subtitle: return NSLocalizedString("Subtitle", comment: "Settings category")
        case .shortcuts: return NSLocalizedString("Shortcuts", comment: "Settings category")
        case .textReplacement: return NSLocalizedString("Text Replacement", comment: "Settings category")
        case .appearance: return NSLocalizedString("Appearance", comment: "Settings category")
        case .apiKeys: return NSLocalizedString("API Keys", comment: "Settings category")
        case .about: return NSLocalizedString("About", comment: "Settings category")
        }
    }

    var icon: String {
        switch self {
        case .speechToText: return "mic.fill"
        case .textToSpeech: return "speaker.wave.2.fill"
        case .translation: return "globe"
        case .subtitle: return "captions.bubble"
        case .shortcuts: return "keyboard"
        case .textReplacement: return "text.badge.plus"
        case .appearance: return "paintbrush"
        case .apiKeys: return "key"
        case .about: return "info.circle"
        }
    }
}

/// Observable navigation state for settings window
/// Allows WindowManager to navigate to a specific category when the window is already open
@Observable
@MainActor
final class SettingsNavigation {
    var selectedCategory: SettingsCategory? = .speechToText
}

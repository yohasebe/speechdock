import SwiftUI

struct UnifiedSettingsView: View {
    @Environment(AppState.self) var appState
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selectedCategory) {
                ForEach(SettingsCategory.allCases) { category in
                    Label {
                        Text(category.displayName)
                    } icon: {
                        Image(systemName: category.icon)
                            .foregroundColor(category.iconColor)
                    }
                    .tag(category)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            detailView(for: navigation.selectedCategory ?? .speechToText)
        }
    }

    @ViewBuilder
    private func detailView(for category: SettingsCategory) -> some View {
        switch category {
        case .speechToText:
            STTSettingsView()
        case .textToSpeech:
            TTSSettingsView()
        case .translation:
            TranslationSettingsView()
        case .subtitle:
            SubtitleSettingsView()
        case .shortcuts:
            ShortcutSettingsView()
        case .textReplacement:
            TextReplacementSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .apiKeys:
            APISettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}

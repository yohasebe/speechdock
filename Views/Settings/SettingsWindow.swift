import SwiftUI

struct SettingsWindow: View {
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        UnifiedSettingsView(navigation: navigation)
            .frame(width: 700, height: 500)
            .focusEffectDisabled()
    }
}

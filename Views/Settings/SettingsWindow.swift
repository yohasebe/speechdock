import SwiftUI

struct SettingsWindow: View {
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        UnifiedSettingsView(navigation: navigation)
            .frame(minWidth: 700, maxWidth: 700, minHeight: 450, idealHeight: 500, maxHeight: .infinity)
            .focusEffectDisabled()
    }
}

import SwiftUI

struct AboutView: View {
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 16) {
            // App Icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            // App Name
            Text("SpeechDock")
                .font(.system(size: 24, weight: .bold))

            // Version
            Text("Version \(appVersion) (\(buildNumber))")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Description
            Text("Speech-to-Text and Text-to-Speech\nfor macOS")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Divider()
                .frame(width: 200)

            // Author
            VStack(spacing: 4) {
                Text("Created by")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Yoichiro Hasebe")
                    .font(.callout)
            }

            // Copyright
            Text("\u{00A9} 2026 Yoichiro Hasebe. All rights reserved.")
                .font(.caption2)
                .foregroundColor(.secondary)

            // GitHub Link
            Button(action: {
                if let url = URL(string: "https://github.com/yohasebe/SpeechDock") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("GitHub Repository")
                }
                .font(.caption)
            }
            .buttonStyle(.link)
        }
        .padding(30)
        .frame(width: 300, height: 400)
    }
}

#Preview {
    AboutView()
}

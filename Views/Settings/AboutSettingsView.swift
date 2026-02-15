import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject private var sparkleUpdater = SparkleUpdater.shared
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            // App Icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            // App Name & Version
            Text("SpeechDock")
                .font(.system(size: 20, weight: .bold))

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.caption)
                .foregroundColor(.secondary)

            // Copyright
            Text("\u{00A9} 2026 Yoichiro Hasebe")
                .font(.caption2)
                .foregroundColor(.secondary)

            // Links
            HStack(spacing: 16) {
                Button(action: {
                    if let url = URL(string: "https://github.com/yohasebe/SpeechDock") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                        Text("GitHub")
                    }
                    .font(.caption)
                }
                .buttonStyle(.link)

                Button(action: {
                    if let url = URL(string: "https://github.com/yohasebe/speechdock") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "book")
                        Text("Documentation")
                    }
                    .font(.caption)
                }
                .buttonStyle(.link)
            }

            Divider()
                .frame(width: 200)

            // Check for Updates
            Button(action: {
                sparkleUpdater.checkForUpdates()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Check for Updates...")
                }
            }
            .disabled(!sparkleUpdater.canCheckForUpdates)

            Divider()
                .frame(width: 200)

            // Support Links
            VStack(spacing: 6) {
                Text(NSLocalizedString("Support Development", comment: "About view support section title"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Button(action: {
                        if let url = URL(string: "https://github.com/sponsors/yohasebe") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.pink)
                            Text("GitHub Sponsors")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.link)

                    Button(action: {
                        if let url = URL(string: "https://buymeacoffee.com/yohasebe") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "cup.and.saucer.fill")
                                .foregroundColor(.orange)
                            Text("Buy Me a Coffee")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.link)

                    Button(action: {
                        if let url = URL(string: "https://ko-fi.com/yohasebe") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "heart.circle.fill")
                                .foregroundColor(.red)
                            Text("Ko-fi")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

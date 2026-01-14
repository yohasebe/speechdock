import Foundation
import Sparkle

/// Manages automatic updates using Sparkle framework
@MainActor
final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()

    /// The Sparkle updater controller
    private let updaterController: SPUStandardUpdaterController

    /// Published property to track if updates can be checked
    @Published var canCheckForUpdates = false

    private init() {
        // Create the updater controller with default configuration
        // startingUpdater: true means it will automatically check for updates based on user preferences
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Bind canCheckForUpdates to the updater's canCheckForUpdates property
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Manually check for updates
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Get the updater for use in SwiftUI views
    var updater: SPUUpdater {
        updaterController.updater
    }
}

// MARK: - SwiftUI Menu Item Helper

import SwiftUI

/// A SwiftUI view that wraps the Sparkle "Check for Updates" functionality
struct CheckForUpdatesView: View {
    @ObservedObject private var sparkleUpdater = SparkleUpdater.shared

    var body: some View {
        Button(action: {
            sparkleUpdater.checkForUpdates()
        }) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .frame(width: 20)
                Text("Check for Updates...")
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .disabled(!sparkleUpdater.canCheckForUpdates)
    }
}

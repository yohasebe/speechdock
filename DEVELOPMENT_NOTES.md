# Development Notes

This document consolidates implementation details, design decisions, and behavioral specifications for TypeTalk development.

English | [日本語](DEVELOPMENT_NOTES_ja.md)

## Table of Contents

- [Building from Source](#building-from-source)
- [Window Level Hierarchy](#window-level-hierarchy)
- [Settings Persistence](#settings-persistence)
- [Audio Input Sources](#audio-input-sources)
- [STT/TTS Processing Lifecycle](#stttts-processing-lifecycle)
- [Panel Shortcuts](#panel-shortcuts)
- [API Key Management](#api-key-management)
- [Thread Safety](#thread-safety)
- [Cache Management](#cache-management)
- [Permissions](#permissions)
- [UI/UX Guidelines](#uiux-guidelines)
- [Build and Release](#build-and-release)
- [Known Issues and Workarounds](#known-issues-and-workarounds)

---

## Building from Source

### Prerequisites

- Xcode 16.0 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional, for project generation)
- Apple Developer account (for code signing and notarization)

### Build Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/yohasebe/TypeTalk.git
   cd TypeTalk
   ```

2. Generate Xcode project (if using XcodeGen):
   ```bash
   xcodegen generate
   ```

3. Open in Xcode:
   ```bash
   open TypeTalk.xcodeproj
   ```

4. Build and run (Cmd + R)

### Build Scripts

```bash
# Build release version
./scripts/build.sh

# Create DMG installer
./scripts/create-dmg.sh

# Notarize for distribution (requires Apple Developer account)
./scripts/notarize.sh
```

### Environment Variables (Development Only)

For development, you can set API keys using environment variables instead of the Settings UI:

```bash
export OPENAI_API_KEY="your-openai-key"
export GEMINI_API_KEY="your-gemini-key"
export ELEVENLABS_API_KEY="your-elevenlabs-key"
```

Note: Environment variables are only for development. Production users should configure API keys through the Settings UI (stored securely in macOS Keychain).

---

## Window Level Hierarchy

macOS window levels used in TypeTalk (from lowest to highest):

| Level | Value | Usage |
|-------|-------|-------|
| `.normal` | 0 | Standard windows |
| `.floating` | 3 | Settings window |
| `.popUpMenu` | 101 | Menu bar popover |
| `popUpMenu + 1` | 102 | STT/TTS floating panels |
| `popUpMenu + 2` | 103 | Save dialogs (NSSavePanel) |

### Design Rationale

- **Menu bar popover** should appear BELOW STT/TTS panels so users can work with panels without accidental menu interactions
- **Save dialogs** should appear ABOVE STT/TTS panels so users can interact with them
- **Settings window** uses standard `.floating` level

### Save Dialog Configuration

```swift
savePanel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.popUpMenu.rawValue) + 2)
savePanel.contentMinSize = NSSize(width: 400, height: 250)
savePanel.setContentSize(NSSize(width: 500, height: 350))
```

---

## Settings Persistence

### Persisted Settings (saved to UserDefaults)

| Setting | Key | Notes |
|---------|-----|-------|
| STT Provider | `selectedRealtimeProvider` | |
| STT Model | `selectedRealtimeSTTModel` | |
| TTS Provider | `selectedTTSProvider` | |
| TTS Voice | `selectedTTSVoice` | |
| TTS Model | `selectedTTSModel` | |
| TTS Speed | `selectedTTSSpeed` | |
| STT Language | `selectedSTTLanguage` | |
| TTS Language | `selectedTTSLanguage` | |
| Audio Input Source Type | `selectedAudioInputSourceType` | **Exception: App Audio resets to Microphone** |
| Microphone Device UID | `selectedAudioInputDeviceUID` | |
| Launch at Login | `launchAtLogin` | |

### Session-Only Settings (NOT persisted)

| Setting | Reason |
|---------|--------|
| `selectedAudioAppBundleID` | App Audio is inherently session-specific |
| `AudioInputSourceType.applicationAudio` | Resets to `.microphone` on app restart |

### Implementation Details

```swift
// In loadPreferences()
if audioSourceType == .applicationAudio {
    selectedAudioInputSourceType = .microphone  // Reset App Audio to Microphone
}

// In savePreferences()
let sourceTypeToSave = selectedAudioInputSourceType == .applicationAudio
    ? .microphone
    : selectedAudioInputSourceType
```

---

## Audio Input Sources

### Available Sources

| Source | Settings Panel | Menu Bar | STT Panel | Notes |
|--------|---------------|----------|-----------|-------|
| Microphone | Yes | Yes | Yes | Default source |
| System Audio | Yes | Yes | Yes | Requires Screen Recording permission |
| App Audio | **No** | Yes | Yes | Session-only, requires Screen Recording |

### Microphone Device Selection

- Available in: Menu Bar, STT Panel
- NOT available in: Settings Panel (too granular for general settings)
- Persisted: Yes (`selectedAudioInputDeviceUID`)

### App Audio Behavior

- Selection is session-only (resets on app restart)
- Not shown in Settings panel (only runtime selection via Menu Bar or STT Panel)
- Requires running application to capture from
- App list can be refreshed from audio source menu

---

## STT/TTS Processing Lifecycle

### Panel Close Behavior

When STT or TTS panel is closed (by any method):

1. **STT Recording**: Automatically cancelled via `cancelRecording()`
2. **TTS Playback**: Automatically stopped via `stopTTS()`
3. **Loading State**: Cancelled if in progress

Implementation in `FloatingWindowManager.setupWindowCloseObserver()`:

```swift
NotificationCenter.default.addObserver(
    forName: NSWindow.willCloseNotification,
    object: window,
    queue: .main
) { [weak self] _ in
    if let appState = self?.currentAppState {
        if appState.isRecording {
            appState.cancelRecording()
        }
        if appState.ttsState == .speaking || appState.ttsState == .loading {
            appState.stopTTS()
        }
    }
}
```

### Cmd+Q Behavior

- When STT/TTS panel is visible: Closes panel only (does NOT quit app)
- When no panel is visible: Quits app normally

### Application Termination

- Uses `MainActor.assumeIsolated` for safe synchronous access to @MainActor state
- Cancels any active STT/TTS before allowing termination
- Returns `.terminateCancel` if processing is active, then terminates after cleanup

### Transcription Timeout Protection

To prevent potential deadlock from stuck `isTranscribing` flag:

```swift
private let transcriptionTimeout: TimeInterval = 30.0
private var transcriptionStartTime: Date?

// Auto-reset if stuck for too long
if isTranscribing, let startTime = transcriptionStartTime {
    if Date().timeIntervalSince(startTime) > transcriptionTimeout {
        isTranscribing = false
        transcriptionStartTime = nil
    }
}
```

---

## Panel Shortcuts

### Global Shortcuts (customizable)

| Action | Default | Setting Key |
|--------|---------|-------------|
| Start/Stop Recording (STT) | `Ctrl + Cmd + S` | `sttToggle` |
| Read Selected Text (TTS) | `Ctrl + Cmd + T` | `ttsToggle` |

### STT Panel Shortcuts (customizable)

| Action | Default | Setting Key |
|--------|---------|-------------|
| Record | `Cmd + R` | `sttRecord` |
| Stop Recording | `Cmd + S` | `sttStop` |
| Paste Text | `Cmd + Return` | `sttPaste` |
| Select Target | `Cmd + Shift + Return` | `sttSelectTarget` |
| Cancel | `Cmd + .` | `sttCancel` |

### TTS Panel Shortcuts (customizable)

| Action | Default | Setting Key |
|--------|---------|-------------|
| Speak | `Cmd + Return` | `ttsSpeak` |
| Stop | `Cmd + .` | `ttsStop` |
| Save Audio | `Cmd + S` | `ttsSave` |

### Modifier Key Support

All panel shortcuts support modifier combinations:
- Command (⌘)
- Shift (⇧)
- Option (⌥)
- Control (⌃)

---

## API Key Management

### Storage

- **Primary**: macOS Keychain (secure, recommended)
- **Alternative**: Environment variables (for development only)

### Supported Environment Variables

```bash
OPENAI_API_KEY
GEMINI_API_KEY
ELEVENLABS_API_KEY
```

### Security Notes

- `~/.typetalk.env` config file support was **removed** for security reasons
- Debug logging is wrapped in `#if DEBUG` to prevent information leakage
- API keys are never logged, even in debug mode

### KeychainService Thread Safety

```swift
private let lock = NSLock()

func save(key: String, data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    // ... keychain operations
}
```

---

## Thread Safety

### Timer Management (MacOSTTS)

Timers must check `self` synchronously before creating async tasks:

```swift
highlightTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
    // Check self synchronously FIRST to invalidate timer immediately if deallocated
    guard self != nil else {
        timer.invalidate()
        return
    }
    Task { @MainActor [weak self] in
        guard let self = self else { return }
        // ... timer logic
    }
}
```

### Clipboard Operations

- Use thread-safe locking for clipboard access
- Implement race condition protection
- Preserve clipboard state with external modification detection
- Add retry logic for paste operations

### MainActor Isolation

For synchronous access to @MainActor state in non-async contexts:

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return MainActor.assumeIsolated {
        // Safe access to @MainActor properties
        let appState = AppState.shared
        // ...
    }
}
```

---

## Cache Management

### TTS Voice Cache

- Cached per provider in `TTSVoiceCache`
- Expiration check required before using cached data:

```swift
if let cached = TTSVoiceCache.shared.getCachedVoices(for: provider),
   !cached.isEmpty,
   !TTSVoiceCache.shared.isCacheExpired(for: provider) {
    return cached
}
return Self.defaultVoices
```

### Temporary Files

- Cleaned up on app startup and termination
- Location: System temporary directory
- Pattern: `typetalk_*` prefix

---

## Permissions

### Required Permissions

| Permission | Purpose | When Prompted |
|------------|---------|---------------|
| Microphone | STT recording | First STT use |
| Accessibility | Global shortcuts, text insertion | First launch |
| Screen Recording | Window thumbnails, System/App Audio | First use of relevant feature |

### Permission Handling

- App prompts on first launch if not granted
- Accessory apps (no dock icon) require special handling for permission alerts
- Use `NSApp.setActivationPolicy(.regular)` temporarily for proper window activation

---

## UI/UX Guidelines

### Text and Labels

- All UI text should be in English (no Japanese in tooltips or labels)
- Use consistent terminology across the app

### Provider Badges

- Show current provider in panel headers
- Format: "Provider: [name]" with accent color background

### Error Display

- Show errors in overlay within the panel
- Include actionable information when possible
- Auto-clear transient errors

### Word Highlighting (TTS)

- Gradient highlight: current word + 2 words before/after
- Alpha values: current=0.45, adjacent=0.25, distant=0.12
- Uses CFStringTokenizer for accurate word boundary detection

---

## Build and Release

### Version Management

- Follow Semantic Versioning (MAJOR.MINOR.PATCH)
- Update version in project settings before release
- Tag releases with `v` prefix (e.g., `v0.1.3`)

### Release Checklist

1. Update CHANGELOG.md
2. Update version number
3. Build release version (`./scripts/build.sh`)
4. Create DMG (`./scripts/create-dmg.sh`)
5. Notarize (`./scripts/notarize.sh`)
6. Create GitHub release with tag
7. Upload DMG to release

---

## Known Issues and Workarounds

### App Activation After Launch

Apps launched via LaunchServices (`open` command) may need multiple activation attempts:

```swift
private func activateWindowWithRetry(attempt: Int = 0) {
    guard let window = floatingWindow, attempt < 20 else { return }
    if window.isKeyWindow { return }

    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.activateWindowWithRetry(attempt: attempt + 1)
    }
}
```

### Text View Focus

SwiftUI TextEditor in floating windows requires explicit focus handling:
- Observe `NSWindow.didBecomeKeyNotification`
- Recursively find NSTextView in view hierarchy
- Call `window.makeFirstResponder(textView)`

---

*Last updated: 2026-01-13*

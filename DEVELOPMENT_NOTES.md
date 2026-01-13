# Development Notes

Technical documentation for TypeTalk developers.

English | [日本語](DEVELOPMENT_NOTES_ja.md)

## Table of Contents

- [Building from Source](#building-from-source)
- [Project Structure](#project-structure)
- [Architecture](#architecture)
- [Implementation Details](#implementation-details)
- [Build and Release](#build-and-release)
- [Known Issues and Workarounds](#known-issues-and-workarounds)

---

## Building from Source

### Prerequisites

- Xcode 16.0 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Apple Developer account (for code signing and notarization)

### Build Steps

```bash
# Clone repository
git clone https://github.com/yohasebe/TypeTalk.git
cd TypeTalk

# Generate Xcode project
xcodegen generate

# Open in Xcode
open TypeTalk.xcodeproj

# Build and run (Cmd + R)
```

### Development API Keys

For development, you can set API keys via environment variables:

```bash
export OPENAI_API_KEY="your-key"
export GEMINI_API_KEY="your-key"
export ELEVENLABS_API_KEY="your-key"
```

Note: Production users configure keys through Settings UI (stored in macOS Keychain).

---

## Project Structure

```
TypeTalk/
├── App/
│   ├── TypeTalkApp.swift      # App entry point
│   ├── AppState.swift         # Global state management
│   ├── AppDelegate.swift      # App lifecycle
│   ├── StatusBarManager.swift # Menu bar management
│   └── WindowManager.swift    # Window management
├── Services/
│   ├── TTS/                   # Text-to-Speech implementations
│   ├── RealtimeSTT/           # Speech-to-Text implementations
│   ├── AudioInputManager.swift
│   ├── AudioOutputManager.swift
│   └── KeychainService.swift
├── Views/
│   ├── MenuBarView.swift
│   ├── FloatingWindow/        # STT/TTS panels
│   └── Settings/              # Settings window
├── Resources/
│   ├── Info.plist
│   └── Assets.xcassets
└── Scripts/
    ├── build.sh
    ├── create-dmg.sh
    └── notarize.sh
```

---

## Architecture

### State Management

- `AppState`: Observable singleton managing all app state
- Settings persisted to UserDefaults
- API keys stored in macOS Keychain

### Provider Pattern

STT and TTS use protocol-based provider pattern:

```swift
protocol TTSService {
    func speak(text: String) async throws
    func availableVoices() -> [TTSVoice]
    func availableModels() -> [TTSModelInfo]
    var audioOutputDeviceUID: String { get set }
}
```

Implementations: `MacOSTTS`, `OpenAITTS`, `GeminiTTS`, `ElevenLabsTTS`

### Window Level Hierarchy

| Level | Value | Usage |
|-------|-------|-------|
| `.floating` | 3 | Settings window |
| `.popUpMenu` | 101 | Menu bar popover |
| `popUpMenu + 1` | 102 | STT/TTS panels |
| `popUpMenu + 2` | 103 | Save dialogs |

Design: Panels appear above menu bar popover; save dialogs appear above panels.

---

## Implementation Details

### Settings Persistence

Persisted settings (UserDefaults):

| Setting | Key |
|---------|-----|
| STT Provider | `selectedRealtimeProvider` |
| STT Model | `selectedRealtimeSTTModel` |
| TTS Provider | `selectedTTSProvider` |
| TTS Voice | `selectedTTSVoice` |
| TTS Model | `selectedTTSModel` |
| TTS Speed | `selectedTTSSpeed` |
| STT Language | `selectedSTTLanguage` |
| TTS Language | `selectedTTSLanguage` |
| Audio Input Source | `selectedAudioInputSourceType` |
| Microphone Device | `selectedAudioInputDeviceUID` |
| Audio Output Device | `selectedAudioOutputDeviceUID` |
| Launch at Login | `launchAtLogin` |

Session-only settings (NOT persisted):
- `selectedAudioAppBundleID` - App Audio resets to Microphone on restart

### Audio Output Device Selection

Uses AVAudioEngine for custom output device support:

```swift
// AVAudioPlayer for system default
if outputDeviceUID.isEmpty {
    try playWithAudioPlayer(url: tempURL)
} else {
    // AVAudioEngine for custom device
    try playWithAudioEngine(url: tempURL)
}
```

Setting output device via Core Audio:

```swift
AudioUnitSetProperty(
    audioUnit,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &deviceID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)
```

### Panel Lifecycle

When panel closes:
1. STT: `cancelRecording()` called
2. TTS: `stopTTS()` called
3. Loading state: cancelled

Cmd+Q behavior:
- Panel visible: closes panel only
- No panel: quits app

### Thread Safety

Timer management pattern:

```swift
Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
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

MainActor isolation for sync contexts:

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return MainActor.assumeIsolated {
        // Safe access to @MainActor properties
    }
}
```

### Keychain Security

```swift
private let lock = NSLock()

func save(key: String, data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    // keychain operations
}
```

- Thread-safe with NSLock
- API keys never logged
- `~/.typetalk.env` support removed for security

### Cache Management

TTS Voice Cache:

```swift
if let cached = TTSVoiceCache.shared.getCachedVoices(for: provider),
   !cached.isEmpty,
   !TTSVoiceCache.shared.isCacheExpired(for: provider) {
    return cached
}
return Self.defaultVoices
```

Temporary files:
- Location: System temp directory
- Pattern: `tts_*.wav`, `tts_*.mp3`
- Cleanup: 5 minutes after creation

---

## Build and Release

### Version Management

Update version in:
- `project.yml` (`MARKETING_VERSION`)
- `Resources/Info.plist` (`CFBundleShortVersionString`)

Then regenerate project:

```bash
xcodegen generate
```

### Build Scripts

```bash
# Build release
./scripts/build.sh

# Create DMG
./scripts/create-dmg.sh

# Notarize
./scripts/notarize.sh
```

### Release Checklist

1. Update CHANGELOG.md
2. Update version in project.yml and Info.plist
3. Run `xcodegen generate`
4. Build release: `./scripts/build.sh`
5. Create DMG: `./scripts/create-dmg.sh`
6. Notarize: `./scripts/notarize.sh`
7. Create GitHub release with tag (e.g., `v0.1.4`)
8. Upload DMG

---

## Known Issues and Workarounds

### App Activation After Launch

Apps launched via LaunchServices need multiple activation attempts:

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

### Text View Focus in Floating Windows

SwiftUI TextEditor requires explicit focus handling:

1. Observe `NSWindow.didBecomeKeyNotification`
2. Find NSTextView in view hierarchy
3. Call `window.makeFirstResponder(textView)`

### AVAudioEngine Completion Handler

Use `.dataPlayedBack` completion type to ensure handler is called after audio finishes playing:

```swift
playerNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
    // Called when audio actually finishes playing
}
```

---

*Last updated: 2026-01-13*

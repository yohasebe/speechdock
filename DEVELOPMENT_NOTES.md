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
| VAD Min Recording Time | `vadMinimumRecordingTime` |
| VAD Silence Duration | `vadSilenceDuration` |

Session-only settings (NOT persisted):
- `selectedAudioAppBundleID` - App Audio resets to Microphone on restart

### STT Language Support

#### Provider Language Capabilities

| Provider | Supported Languages | Auto Detection |
|----------|---------------------|----------------|
| macOS | System-installed only | No (uses system locale) |
| Local Whisper | 99 languages | Yes |
| OpenAI Realtime | 50+ languages | Yes |
| Gemini Live | 24 languages | Yes |
| ElevenLabs Scribe | 90+ languages | Yes |

#### Language Selection Design

The language picker shows a **curated subset of 26 common languages** rather than all supported languages:

- English, Japanese, Chinese, Korean, Spanish, French, German, Italian, Portuguese, Russian, Arabic, Hindi
- Dutch, Polish, Turkish, Indonesian, Vietnamese, Thai
- Bengali, Gujarati, Kannada, Malayalam, Marathi, Tamil, Telugu

**Rationale:**
1. Keeps the UI manageable (a picker with 99 items is unwieldy)
2. Covers the most commonly used languages
3. "Auto" detection handles languages not in the list

**Provider-specific adjustments:**
- **macOS**: Shows only system-installed languages (queried via `SFSpeechRecognizer.supportedLocales()`)
- **Gemini**: Excludes Portuguese (not supported by Gemini Live API)
- **Others**: Show the full common language list

**Important:** Languages not in the picker can still be recognized when "Auto" is selected. The picker is for explicitly specifying a language to improve accuracy, not a limitation of what the provider can recognize.

#### Adding New Languages

To add a new language to the picker:

1. Add the case to `LanguageCode` enum in `Models/LanguageCode.swift`
2. Add `displayName` for the new language
3. Add mappings in `toLocaleIdentifier()` and `toElevenLabsTTSCode()`
4. Add to `commonLanguages` array (or provider-specific array if needed)

### Local Whisper (WhisperKit) Model Storage

#### Model Storage Location

WhisperKit models are stored in the user's Documents folder:

```
~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/
```

This is WhisperKit's default storage location, shared across all apps using WhisperKit.

#### Available Models

| Model | Type | Size | Description |
|-------|------|------|-------------|
| Tiny | Multilingual | ~39MB | Fastest, lowest accuracy |
| Tiny (English) | English only | ~39MB | Faster for English |
| Base | Multilingual | ~74MB | Fast, good accuracy |
| Base (English) | English only | ~74MB | Recommended for English |
| Small | Multilingual | ~244MB | Balanced speed/accuracy |
| Small (English) | English only | ~244MB | Recommended for English |
| Medium | Multilingual | ~769MB | High accuracy |
| Large v2 | Multilingual | ~1.5GB | Very high accuracy |
| Large v3 | Multilingual | ~1.5GB | Best accuracy |
| Large v3 Turbo | Multilingual | ~800MB | Fast + high accuracy |

#### App Uninstallation Behavior

When TypeTalk is uninstalled:

| Data | Deleted? | Location |
|------|----------|----------|
| TypeTalk.app | Yes | /Applications |
| WhisperKit models | **No** | ~/Documents/huggingface/ |
| User settings | Depends on uninstaller | ~/Library/Preferences |
| API keys | Depends on uninstaller | Keychain |

**Important:** WhisperKit models persist after app deletion. Users must manually delete them to reclaim disk space:

```bash
rm -rf ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/
```

**Note:** This location may be shared with other WhisperKit-based applications.

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

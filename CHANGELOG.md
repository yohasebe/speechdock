# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.8] - 2026-01-16

### Added
- Subtitle mode for real-time transcription overlay during recording
  - Customizable font size, opacity, position (top/bottom), and max lines
  - Draggable subtitle position with position memory
  - Toggle Subtitle Mode hotkey (`Ctrl + Option + S`)
  - Auto-hide STT panel option when subtitle mode is active
- SpeechAnalyzer support for macOS 26+ (no time limit, improved performance)
- Gemini Live API real-time streaming transcription
- OpenAI Realtime API streaming transcription

### Changed
- Menu bar panel now closes automatically when opening STT/TTS panels or Settings
- Replaced NSPopover with NSPanel for menu bar (more reliable, immediate display)

### Fixed
- Quit TypeTalk now works with single click (was requiring double-click when panels open)
- Subtitle panel dragging is now smooth (was jerky due to frequent state updates)
- Position setting (top/bottom) now works correctly when custom position was set
- Menu bar icon sometimes not responding to clicks (rewrote using NSPanel)

### Internal
- Modernized ClipboardService to use async/await instead of blocking Thread.sleep
- Modernized StatusBarManager image tinting to use NSImage drawing handler instead of deprecated lockFocus/unlockFocus

## [0.1.4] - 2026-01-14

### Added
- Auto-update support via Sparkle framework (checks for updates on startup)
- "Check for Updates..." menu item in menu bar
- Configurable font size for STT/TTS panel text areas (Settings > Appearance)
- VAD auto-stop settings configurable in Settings UI (minimum recording time, silence duration)
- Transcription loading overlay for Local Whisper, OpenAI, and Gemini providers
- Local Whisper STT provider using WhisperKit for on-device transcription
- Hover effect for menu bar action buttons (Start Recording, Read Selected Text)

### Changed
- Close button moved to top-left in STT and TTS panels
- Audio level indicator now has fixed height to prevent layout shifts

### Fixed
- Japanese/Chinese/Korean spacing in Gemini transcription (spurious spaces removed)
- 5-second audio capture delay in Local Whisper, OpenAI, and Gemini (VAD initialization now non-blocking)
- Speed slider alignment in Settings panel (Slow/Fast labels)
- Redundant labels in Settings sliders

## [0.1.3] - 2026-01-13

### Added
- System audio capture support (capture audio from system or specific apps)
- Audio input source selector in STT panel header and menu bar
- Microphone device selection in menu bar and STT panel
- Paste destination validation with warning when target window is no longer available
- Test target with initial unit tests for KeychainService and APIKeyManager
- CONTRIBUTING.md with development guidelines

### Changed
- Removed `~/.typetalk.env` config file support for security reasons
- API keys should now be stored via Settings UI (stored securely in macOS Keychain)
- Environment variables still supported for development use
- App Audio option removed from Settings panel (available only in menu bar and STT panel)
- App Audio settings are now session-only (reset to Microphone on app restart)
- Cmd+Q now closes panel instead of quitting app when STT/TTS panels are visible

### Fixed
- ElevenLabsTTS voice cache expiration check
- Timeout protection for isTranscribing flag to prevent potential deadlock
- applicationShouldTerminate race condition using MainActor.assumeIsolated
- MacOSTTS timer management for immediate invalidation on deallocation
- showTTSWindow flag synchronization issue
- Panel close (by any method) now properly stops STT/TTS processing
- Unsafe force cast in TextSelectionService with proper CFGetTypeID check
- Thread.sleep replaced with non-blocking RunLoop-based waiting in AppDelegate
- Thread safety added to KeychainService with NSLock
- MacOSTTS Process execution made async to avoid blocking main thread

### Security
- Debug logging now wrapped in `#if DEBUG` to prevent information leakage in production
- Removed plaintext API key storage option
- Fixed URL force unwraps in all API clients with proper guard statements
- Added temporary file cleanup on app startup and termination
- Improved clipboard operations with thread-safe locking and race condition protection
- Added clipboard state preservation with external modification detection
- Added retry logic for clipboard paste operations

## [0.1.2] - 2026-01-12

### Fixed
- Permission alerts now properly appear for accessory apps (no dock icon)
- Added debug logging for API key loading and permission checks

## [0.1.1] - 2026-01-12

### Added
- Support for `~/.typetalk.env` config file for API keys (recommended for Finder launch)
- Automatic permission prompts for Microphone and Accessibility on first launch

### Fixed
- API keys from environment variables now work when app is launched from Finder
- TTS provider selector now correctly defaults to macOS when no API keys are available
- UI text now consistently uses English (removed Japanese text from tooltips)

## [0.1.0] - 2026-01-11

### Added
- Initial release of TypeTalk
- **Speech-to-Text (STT)** support with multiple providers:
  - macOS native (Speech Recognition)
  - OpenAI (Whisper, GPT-4o Transcribe)
  - Google Gemini (2.5 Flash)
  - ElevenLabs (Scribe v2, Scribe v1)
- **Text-to-Speech (TTS)** support with multiple providers:
  - macOS native (AVSpeechSynthesizer)
  - OpenAI (GPT-4o Mini TTS, TTS-1, TTS-1 HD)
  - Google Gemini (2.5 Flash TTS, 2.5 Flash Lite TTS)
  - ElevenLabs (Eleven v3, Flash v2.5, Multilingual v2, Turbo v2.5)
- Global keyboard shortcuts for STT and TTS
- Menu bar interface with quick access to all features
- Floating window for real-time transcription display
- Floating window for TTS with text editing and word highlighting
- API key management via macOS Keychain
- Language selection for STT and TTS (Auto-detect or manual selection)
- Speed control for TTS playback
- Voice and model selection per provider
- Launch at login option
- Duplicate instance prevention

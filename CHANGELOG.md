# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Debug/Release build separation for simultaneous development and production use
  - Debug build uses `com.speechdock.app.dev` bundle ID and "SpeechDock Dev" display name
  - Green dot badge on menu bar icon for Debug builds (appearance-aware)
- Rake tasks for Dev workflow (`dev:run`, `dev:quit`, `dev:restart`)
- Homebrew Cask distribution via `yohasebe/homebrew-speechdock` tap
- Stop button on subtitle overlay for convenience
- Unified settings window with NavigationSplitView sidebar (9 categories)
- Multilingual localization: Simplified Chinese (zh-Hans), Korean (ko), German (de), French (fr)
- macOS 26+ Liquid Glass support for menu bar panel
- `Cmd + ,` keyboard shortcut support in menu bar panel
- Reactive permission setup window with real-time status monitoring (replaces quit-and-reopen flow)
  - PermissionService with polling + DistributedNotificationCenter for instant detection
  - Checklist UI showing Microphone (Required), Accessibility (Recommended), Screen Recording (Optional)
  - Permissions update in real-time without app restart
- Screen Recording permission warning in menu bar panel
- Permission-aware UI: buttons and input sources are disabled when required permissions are missing
  - Subtitle Mode and Floating Mic Button disabled without Microphone permission
  - OCR button disabled without Screen Recording permission
  - System Audio / App Audio input sources disabled without Screen Recording permission
  - Automatic fallback to microphone input when Screen Recording permission is revoked

### Changed
- Menu bar panel simplified to quick actions only (settings controls moved to Settings window)
- Settings window restructured from 4 tabs to 9 sidebar categories
- About window integrated into Settings as a category
- Permission checking delegated to PermissionService singleton (replaces inline checks in AppState)
- Subtitle Mode and Floating Mic Button toggles keep menu bar panel open (instead of closing it)
- Menu bar and settings sidebar icons use accent color

### Removed
- Audio input/output selectors from menu bar panel
- STT/TTS provider/model selectors from menu bar panel
- Old permission alert with "Open Settings & Quit" flow (replaced by reactive setup window)

## [0.1.26] - 2026-02-14

### Added
- Real-time subtitle translation with context-aware translation service
  - Per-provider debounce intervals (macOS: 300ms, Gemini: 600ms, OpenAI/Grok: 800ms)
  - LRU translation cache (200 entries) with pause detection (1.5s)
  - Inline translation toggle and language/provider selectors on subtitle overlay
  - Automatic sync of STT panel translation settings to subtitle mode
- macOS on-device translation provider (macOS 26+, no API key required)
- Grok (xAI) as translation provider
- Translation model selection per provider in Settings
- macOS native file transcription via SpeechAnalyzer (macOS 26+, offline)
- Japanese localization
- macOS 26 Liquid Glass UI support for floating panels

### Changed
- Translation controls redesigned: separate language selection from translation execution
- Subtitle translation uses provider's default model to avoid cross-provider conflicts
- Improved permission flow and debounced preferences saving
- Pinned FluidAudio to v0.9.1 for Xcode 26 compatibility

### Fixed
- Force unwraps replaced with safe guard-let patterns across translation services
- Accessibility API force casts now protected with CFGetTypeID checks
- `precondition` in LLMTranslation replaced with debug-only `assert`
- WindowService CFDictionary cast made safe with conditional cast
- Memory leaks and resource cleanup issues
- File transcription robustness and quit behavior improvements

## [0.1.25] - 2026-01-26

### Added
- Jekyll documentation site for project website
- Japanese documentation (README_ja.md, docs)

### Changed
- Improved release workflow with better error handling and auto-install
- Prepared repository for public release

### Fixed
- AppleScript thread safety issues causing app freeze
- AppleScript initialization wait pattern for reliable command execution

## [0.1.24] - 2026-01-25

### Added
- Floating Mic Button for quick transcription without opening STT panel
  - 48px draggable button with position persistence
  - Real-time text display HUD (320x120px)
  - Clipboard-based text insertion to frontmost app
  - Hotkey support (Ctrl+Option+M)
- AppleScript support with 16 commands and read/write properties
  - speak, stop/pause/resume speaking, save audio
  - show/toggle STT/TTS panels, subtitle mode
  - start/stop/toggle quick transcription
  - copy to clipboard, paste text, transcribe file, translate
- Keyboard Shortcuts HUD overlay (Ctrl+Option+/)

### Changed
- Improved AppleScript implementation quality and error handling
- Floating Mic Button uses NonActivatingWindow to prevent focus stealing
- Frontmost app tracking via NSWorkspace notification for reliable text insertion

### Fixed
- Floating mic button not stealing focus from target applications
- AppleScript shortcuts command naming consistency

## [0.1.21] - 2026-01-22

### Added
- RTL (right-to-left) language support for text display
- Translation model selection in Settings (per-provider model choice)

### Fixed
- Grok TTS now prevents agent-like responses (strict verbatim TTS instruction)

## [0.1.19] - 2026-01-22

### Added
- Grok (xAI) as translation provider
- Additional unit tests for TTS, audio conversion, and file transcription

### Changed
- Text selection now uses CGEvent instead of AppleScript (no System Events permission needed)
- Improved TTS text capture from other apps via hotkey

### Fixed
- TTS hotkey text capture when panel is already open
- Translation state properly resets when switching between STT/TTS panels
- Translated text background opacity refined for readability
- Translation revert now restores correct original text
- Text area becomes read-only when showing translated text
- Translation state resets when new text arrives in TTS panel

## [0.1.9] - 2026-01-22

### Added
- Translation feature for STT and TTS panels
  - OpenAI (GPT-5 Nano/Mini/5.2) and Gemini (3 Flash/Pro) providers
  - Inline translation controls with language selector
  - Original/translated text toggle
  - TTS language auto-sync on translation
- Audio file transcription via drag-and-drop or file picker
  - OpenAI Whisper (25MB), Gemini (20MB), ElevenLabs Scribe (25MB)
  - Provider-specific format and size validation
- Grok Realtime API for STT
- ElevenLabs Scribe v2 real-time STT

### Changed
- Renamed app from TypeTalk to SpeechDock
- Removed WhisperKit/Local Whisper provider (replaced by cloud providers)
- Improved STT/TTS panel UI layout and compact button styling

### Fixed
- OpenAI STT Japanese text encoding (Unicode normalization and sanitization)
- Grok STT transcription duplication (response item filtering)
- Gemini STT microphone input (48kHz to 16kHz audio resampling)
- Cmd+Q now closes panels instead of quitting the app
- Translation framework compilation for older SDK builds

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
- Quit SpeechDock now works with single click (was requiring double-click when panels open)
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
- Removed `~/.speechdock.env` config file support for security reasons
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
- Support for `~/.speechdock.env` config file for API keys (recommended for Finder launch)
- Automatic permission prompts for Microphone and Accessibility on first launch

### Fixed
- API keys from environment variables now work when app is launched from Finder
- TTS provider selector now correctly defaults to macOS when no API keys are available
- UI text now consistently uses English (removed Japanese text from tooltips)

## [0.1.0] - 2026-01-11

### Added
- Initial release of SpeechDock
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

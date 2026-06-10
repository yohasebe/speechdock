# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.36] - 2026-06-10

### Changed
- **Subtitle realtime translation responds much faster.** Per-provider debounce intervals shortened to match v0.1.34's faster default LLMs (Gemini 3.1 Flash Lite, GPT-5.4 Mini, Grok 4.1 Fast non-reasoning): macOS 300 → 200 ms, Gemini 600 → 350 ms, OpenAI 800 → 400 ms, Grok 800 → 350 ms. Combined with the new in-flight queue (below), end-to-end "speech → translated subtitle" delay now tracks API latency rather than debounce.
- **Subtitle translation pipeline now queues updates instead of dropping them.** Previously, while a translation request was in flight, every new partial-text update was discarded for the entire 1–2 s the API call took; only the next update after completion triggered a fresh translation. The pipeline now records the latest pending text and immediately fires another translation as soon as the current one completes, so long utterances with continuous OpenAI STT deltas track the spoken text smoothly instead of jumping in chunks.
- **Sparkle bumped from 2.8.1 to 2.9.3.** Picks up the two high-severity security fixes shipped in 2.9.2 (delta-update symlink-attack mitigation and appcast connection validation) and the 2.9.3 fix for initial-install failure on apps whose bundle ID ends in `.app` — directly affects `com.speechdock.app`.

### Fixed
- **ElevenLabs STT WebSocket parameters updated to match current API.** Replaced the `sample_rate` + `encoding` query params with `audio_format=pcm_16000`; the older params are no longer part of the documented API.
- **ElevenLabs STT now surfaces previously-silenced server errors.** Ten error event types (`auth_error`, `quota_exceeded`, `rate_limited`, `queue_overflow`, `resource_exhausted`, `session_time_limit_exceeded`, `chunk_size_exceeded`, `transcriber_error`, etc.) were falling into `default: break` with no user-visible feedback. They are now reported through the standard error delegate path. Two advisory events (`insufficient_audio_activity`, `commit_throttled`) are logged but no longer fatal.

## [0.1.35] - 2026-05-15

### Changed
- **OpenAI STT migrated to the GA Realtime API with streaming Whisper.**
  - New default model: `gpt-realtime-whisper` (replaces `gpt-4o-mini-transcribe-2025-12-15`). The Whisper realtime model emits a steady stream of `.delta` events as you speak, so the subtitle overlay now updates word-by-word during a continuous utterance instead of only when the server finalizes a segment. The other available models (`gpt-4o-mini-transcribe-2025-12-15`, `whisper-1`) only emit `.completed` after each commit — text appears in larger chunks rather than streaming, with higher per-segment accuracy as the trade-off.
  - Session setup switched from the deprecated `transcription_session.update` to GA `session.update` + `session.type: "transcription"` with the nested `audio.input` shape. `noise_reduction` is `near_field` for microphone capture and `far_field` for system-audio capture (videos, app audio).
  - Server VAD is no longer used. `gpt-realtime-whisper` rejects any `turn_detection` value, and the gpt-4o-mini-transcribe family's default server VAD auto-commits every ~200 ms (too aggressive). We now run client-side VAD against `audioLevelMonitor`'s noise-floor-adapted threshold and silence duration (with lower threshold / shorter silence for external sources), and send `input_audio_buffer.commit` ourselves when an utterance ends.
  - Force-commit safeguards: a single segment that runs longer than 60 s without a silence-triggered commit is committed anyway to bound buffer growth. If a `.completed` event fails to arrive within 10 s of a commit, the in-flight flag self-resets so subsequent utterances aren't silently dropped.
  - Existing users on the retired `gpt-4o-transcribe` snapshot are migrated to `gpt-realtime-whisper`. Saved selections of `gpt-4o-mini-transcribe-2025-12-15` or `whisper-1` are preserved.

### Fixed
- Pre-existing state bug: when `startRealtimeSTT` failed (network/API error during the initial `startListening`), `startRecording` still flipped `isRecording = true` and `transcriptionState = .recording`, leaving the menu bar showing "録音中" while the panel displayed the error and a Record button. The transition now short-circuits when `transcriptionState` is `.error`.

## [0.1.34] - 2026-04-28

### Changed
- **Translation models refreshed across all LLM providers**:
  - OpenAI: default `gpt-5-nano` → `gpt-5.4-mini`. Selectable list trimmed to `gpt-5.4-mini` (default) and `gpt-5.4-nano`. Older `gpt-5-*` and `gpt-5.2` IDs are no longer offered; saved selections fall through to the new default.
  - Gemini: default `gemini-3-flash-preview` → `gemini-3.1-flash-lite-preview` (cost roughly halved, low-latency tier optimized for streaming). `gemini-3.1-pro-preview` is the accuracy alternative.
  - Grok: default `grok-3-fast` → `grok-4-1-fast-non-reasoning` (cheaper, lower hallucination, no chain-of-thought overhead). `grok-4-1-fast-reasoning` is the alternative.
- **OpenAI STT**: default migrated from `gpt-4o-transcribe` (retired by OpenAI on 2026-02-28) to `gpt-4o-mini-transcribe-2025-12-15` — the current low-hallucination snapshot. Existing users on the retired ID are auto-migrated.
- **OpenAI TTS**: deprecated models removed from the picker (`gpt-4o-mini-tts` undated, `tts-1`, `tts-1-hd`). Only the dated snapshot `gpt-4o-mini-tts-2025-12-15` remains. Saved selections on removed IDs are auto-migrated to the new default.
- **Gemini STT**: replaced `gemini-2.0-flash-live-001` (deprecated 2026-02-18, scheduled shutdown 2026-06-01) with `gemini-3.1-flash-live-preview` as the secondary option. Existing users on the retired ID are auto-migrated.
- **ElevenLabs TTS**: trimmed picker to current generations only — `eleven_v3` (default) and `eleven_flash_v2_5` (low-latency). Older `eleven_multilingual_v2` / `eleven_turbo_v2_5` / `eleven_monolingual_v1` are auto-migrated to `eleven_v3`.
- File-transcription `STTModel` enum: `gpt-4o-transcribe` case removed (matching the realtime-side migration).

### Fixed
- **Gemini translation with thinking-capable models**: `gemini-3.1-pro-preview` always returns chain-of-thought parts (`"thought": true`) before the answer; the old parser grabbed the reasoning trace via `parts.first?["text"]` and translation appeared to silently fail. The parser now skips thought parts and concatenates remaining text. `thinkingConfig.thinkingLevel: "low"` is also requested to suppress thinking on Flash models where supported.
- **Gemini STT audio frame format**: switched `realtimeInput` audio payload from the deprecated `mediaChunks` array to `realtimeInput.audio`. The old form was rejected by `gemini-3.1-flash-live-preview` with a 1007 close (`realtime_input.media_chunks is deprecated. Use audio, video, or text instead.`); the new form works for both 2.5 Native Audio and 3.1 Flash Live.

## [0.1.33] - 2026-04-27

### Changed
- **Grok STT migrated to xAI's dedicated streaming API** (`wss://api.x.ai/v1/stt`).
  - Previously used the Voice Agent endpoint (`/v1/realtime`), which forced an AI audio reply for every utterance and blocked subsequent input — long sessions lost most of what was said. The new endpoint is transcription-only, so the issue is gone.
  - Audio is now sent as raw binary WebSocket frames; configuration is via URL query params (`sample_rate`, `encoding`, `interim_results`, `endpointing`, `language`).
  - Endpointing duration is computed adaptively from the live noise floor (range 300–800 ms for microphone, 250 ms for external audio).
  - The model ID `grok-2-public` is migrated automatically to `grok-stt` on next launch.
  - Display name changed from "Grok 2" / "Grok Realtime" to "Grok STT".
- **Grok TTS legacy Voice Agent code removed** (~340 lines). The dedicated `/v1/tts` REST API has been the active path since v0.1.31; the unused WebSocket path, system-prompt scaffolding, and PCM→M4A conversion have been deleted.

### Fixed
- Grok STT: send `language=xx` hint for supported languages (improves accuracy), but auto-detect for codes verified to silently stall on the xAI server (currently `ja`).
- Grok STT: wait up to 1.5 s for `transcript.done` after `audio.done` before closing the WebSocket, so the server-authoritative final transcript is captured instead of being cut off.
- Grok STT: dedupe finalized partials by `(start, text)` so xAI's two-event-per-utterance pattern (is_final, then speech_final with same text) no longer doubles the text. Robust to xAI dropping either flag in future revisions.
- `FileTranscriptionServiceTests.testFileTranscriptionError_FileNotFound` no longer fails on non-English locales (the assertion was comparing localized output to a hard-coded English string).

### Internal
- `dprint` now also forwards to `os_log` (subsystem `com.speechdock.app.dev`, category `debug`) in DEBUG builds, so `log stream --predicate 'subsystem == "com.speechdock.app.dev"' --level debug` surfaces app diagnostics without launching the binary from a terminal. Release builds are unaffected.

## [0.1.32] - 2026-04-21

### Fixed
- Subtitle overlay translation menu was inaccessible when STT language matched the translation target. The globe icon became disabled and the provider/language selectors were hidden at the same time, leaving no way to change the target language. Provider/language selectors are now shown in that state so users can pick a different target and re-enable translation.

### Changed
- Subtitle mode toggle unified into a single segmented control (Panel / Subtitle) in the STT panel header, replacing the duplicate subtitle indicator and footer toggle button.
- Subtitle overlay header UI: increased font sizes for the recording indicator, Stop button, font size / max lines controls, and provider/language selectors for better readability without changing subtitle text defaults.
- Subtitle overlay: maximum lines setting range extended from 2–6 to 2–8.

### Added
- "Panel" localization across en/ja/de/fr/ko/zh-Hans.

## [0.1.31] - 2026-04-18

### Added
- Gemini 3.1 Flash TTS as the Gemini TTS model (replaces 2.5 Flash/Pro TTS in the picker)
  - Dedicated TTS model with expressive inline voice tags (`[whispers]`, `[excited]`, etc.) and improved naturalness
  - REST-only — bypasses the Live API streaming path since this model does not support WebSocket streaming
  - Existing users on deprecated 2.5 Flash/Pro TTS settings are migrated automatically to 3.1 on next launch
- Grok TTS via xAI's dedicated TTS REST API (replaces the Voice Agent Realtime workaround in the picker)
  - 5 voices (eve, ara, rex, sal, leo) with 20+ languages and auto-detection
  - Supports inline expressive tags (`[pause]`, `[laugh]`, `[sigh]`, `[gulp]`) and wrapping tags (`<whisper>`, `<soft>`, `<loud>`, `<slow>`, `<fast>`)
  - Legacy Voice Agent WebSocket path is retained in the code for potential future use but no longer selectable
  - Existing users on `grok-2-public` are migrated automatically to `grok-tts` on next launch
- Inline voice-tag hints in the empty TTS panel placeholder for Gemini, Grok, and ElevenLabs v3
- Speed slider now disabled (with guidance text) for models without an API speed parameter: Gemini 3.1 Flash TTS, Grok TTS, and OpenAI gpt-4o-mini-tts
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
- Removed FluidAudio dependency and unused VADService (server-side VAD unaffected)
- Updated xcodeVersion to 26.0 for Xcode 26 / Swift 6.3 compatibility

### Fixed
- Preserve paragraph breaks when pasting selected text from rich-text sources
  - Browsers (Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi, Opera, etc.) and rich-text editors (TextEdit, Mail, Notes, Pages, Word, Outlook, etc.) now use the clipboard HTML/RTF path instead of Accessibility API, which collapsed blank lines between paragraphs
  - Auto-paste logic picks the representation (plain text / HTML / RTF) that best preserves paragraph structure
  - HTML parser preprocessing injects `<br><br>` after block-level closing tags so NSAttributedString's parser emits proper `\n\n` paragraph boundaries
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

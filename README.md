<p align="center">
  <img src="assets/logo.png" alt="SpeechDock Logo" width="128" height="128">
</p>

# SpeechDock

A macOS menu bar application for Speech-to-Text (STT) and Text-to-Speech (TTS) with support for multiple providers.

**Always accessible from your menu bar** - Use STT and TTS anywhere on your Mac with global hotkeys. Transcribe not only your voice but also system audio or audio from specific apps. Read aloud typed text, pasted content, or text captured via OCR from any screen region.

**Ready to use immediately after installation** - No API keys or additional downloads required. macOS native STT and TTS work out of the box. Cloud providers and Local Whisper are optional enhancements.

English | [日本語](README_ja.md)

## Features

### Speech-to-Text (STT)

Convert speech to text using:

| Provider | Models | API Key |
|----------|--------|---------|
| **macOS Native** | System Default (SpeechAnalyzer on macOS 26+) | Not required |
| **Local Whisper** | Tiny, Base, Small, Medium, Large v2/v3, Large v3 Turbo | Not required |
| **OpenAI** | GPT-4o Transcribe, GPT-4o Mini Transcribe, Whisper | Required |
| **Google Gemini** | Gemini 2.5 Flash, Gemini 2.0 Flash, Gemini 1.5 Pro | Required |
| **ElevenLabs** | Scribe v2 Realtime | Required |

**Note**: On macOS 26+, the native STT uses Apple's new SpeechAnalyzer framework, providing real-time transcription without time limits and improved performance.

### Text-to-Speech (TTS)

Convert text to speech using:

| Provider | Models | API Key |
|----------|--------|---------|
| **macOS Native** | System Default | Not required |
| **OpenAI** | GPT-4o Mini TTS (Dec 2025), GPT-4o Mini TTS, TTS-1, TTS-1 HD | Required |
| **Google Gemini** | Gemini 2.5 Flash TTS, Gemini 2.5 Pro TTS | Required |
| **ElevenLabs** | Eleven v3, Flash v2.5, Multilingual v2, Turbo v2.5, Monolingual v1 | Required |

### OCR to Speech

Capture text from any region of your screen and convert it to speech:

1. Press the OCR hotkey (`Ctrl + Option + Shift + O` by default)
2. Drag to select the region containing text
3. Recognized text appears in the TTS panel for editing
4. Press Speak to read the text aloud

Uses macOS Vision Framework for text recognition. Requires Screen Recording permission.

### Subtitle Mode

Display real-time transcription as subtitles overlay during recording:

- **On-screen subtitles** - Show transcription as floating subtitles anywhere on screen
- **Customizable appearance** - Adjust font size, opacity, position (top/bottom), and max lines
- **Draggable position** - Drag subtitles to any location on screen
- **Auto-hide panel** - Optionally hide STT panel when subtitle mode is active

Toggle with hotkey (`Ctrl + Option + S` by default) or from the STT panel/menu bar.

### Audio Sources

- **Microphone** - Record from any connected microphone with device selection
- **System Audio** - Capture all audio output from your Mac
- **App Audio** - Capture audio from a specific application

### Additional Features

- Global keyboard shortcuts for STT and TTS
- Customizable panel shortcuts with modifier key support
- Panel windows for real-time transcription with paste target selection
- Panel windows for TTS with text editing and word highlighting
- Panel style selection: Floating (always-on-top) or Standard Window
- Audio output device selection for TTS
- Save synthesized audio to file (M4A/MP3 format)
- Language selection for STT and TTS
- Speed control for TTS playback
- Voice and model selection per provider
- VAD (Voice Activity Detection) auto-stop for hands-free recording
- Text replacement rules for STT output correction
- Automatic updates via Sparkle
- Launch at login option

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac (M1/M2/M3/M4)
- API keys for cloud providers are **optional** (required only if using OpenAI, Google Gemini, or ElevenLabs)

## Installation

1. Download the latest `.dmg` file from the [Releases](https://github.com/yohasebe/SpeechDock/releases) page
2. Open the DMG file
3. Drag SpeechDock to your Applications folder
4. Launch SpeechDock from Applications

## Setup

### API Keys

To use cloud providers, you need to configure API keys:

1. Open **Settings** > **API Keys**
2. Enter your API keys:
   - **OpenAI**: [OpenAI Platform](https://platform.openai.com/api-keys)
   - **Google Gemini**: [Google AI Studio](https://aistudio.google.com/apikey)
   - **ElevenLabs**: [ElevenLabs Settings](https://elevenlabs.io/app/settings/api-keys)

API keys are securely stored in macOS Keychain.

### Local Whisper (Optional)

Local Whisper runs speech recognition entirely on your Mac without sending audio to the cloud. Models are downloaded on first use:

| Model | Size | Description |
|-------|------|-------------|
| Tiny | ~39 MB | Fastest, lower accuracy |
| Base | ~74 MB | Fast, basic accuracy |
| Small | ~244 MB | Balanced speed/accuracy |
| Medium | ~769 MB | High accuracy |
| Large v3 Turbo | ~800 MB | Fast + accurate (recommended) |
| Large v2/v3 | ~1.5 GB | Best accuracy, slower |

Models are stored in `~/Library/Caches/com.speechdock.app/` and can be deleted to free disk space.

### Permissions

SpeechDock requires the following permissions:

| Permission | Purpose |
|------------|---------|
| **Microphone** | Speech recognition input |
| **Accessibility** | Global keyboard shortcuts and text insertion |
| **Screen Recording** | Window thumbnails and System/App Audio capture |

Grant permissions in **System Settings** > **Privacy & Security**. SpeechDock will prompt you on first use.

## Usage

### Keyboard Shortcuts

| Action | Default Shortcut |
|--------|------------------|
| Toggle STT Panel | `Cmd + Shift + Space` |
| Toggle TTS Panel | `Ctrl + Option + T` |
| OCR Region to Speech | `Ctrl + Option + Shift + O` |
| Toggle Subtitle Mode | `Ctrl + Option + S` |

Shortcuts can be customized in **Settings** > **Shortcuts**.

### STT Panel

| Action | Default Shortcut |
|--------|------------------|
| Record | `Cmd + R` |
| Stop Recording | `Cmd + S` |
| Paste Text | `Cmd + Return` |
| Select Target | `Cmd + Shift + Return` |
| Cancel | `Cmd + .` |

### TTS Panel

| Action | Default Shortcut |
|--------|------------------|
| Speak | `Cmd + Return` |
| Stop | `Cmd + .` |
| Save Audio | `Cmd + S` |

### Menu Bar

Click the SpeechDock icon in the menu bar to:

- Start/stop STT recording
- Start TTS for selected text
- Select audio input source and device
- Select audio output device
- Change providers and settings
- Access settings

### Audio Input Selection

Select audio input from the **Menu Bar** or **STT Panel**:

- **Microphone**: Choose from available microphone devices
- **System Audio**: Capture all Mac audio output
- **App Audio**: Capture audio from a specific running application

Note: System Audio and App Audio require Screen Recording permission.

### Audio Output Selection

Select audio output device from **Settings**, **Menu Bar**, or **TTS Panel** to route TTS playback to a specific speaker or headphone.

## Configuration

### Settings

- **General**: Select STT/TTS providers, models, voices, languages, playback speed, and panel style
- **Shortcuts**: Customize global hotkeys and panel shortcuts
- **Text Replacement**: Define rules to automatically correct or replace text in STT output
- **API Keys**: Manage API keys for cloud providers

### Panel Style

Choose between two panel styles in **Settings** > **General**:

- **Floating**: Always-on-top borderless panels that can be dragged from anywhere
- **Standard Window**: Regular macOS windows with title bar, can be minimized

Note: Only one panel (STT or TTS) can be open at a time. Opening one will close the other.

### Language Selection

Both STT and TTS support language selection:

- **Auto** (default): Automatically detects the language
- **Manual**: Choose from supported languages including English, Japanese, Chinese, Korean, Spanish, French, German, Italian, Portuguese, Russian, Arabic, and Hindi

### Launch at Login

Enable **Launch at Login** in **Settings** > **General** to start SpeechDock automatically.

## Troubleshooting

### STT not working

1. Check microphone permission is granted
2. Verify API key is configured (for cloud providers)
3. Try macOS native provider to test basic functionality
4. For System/App Audio, check Screen Recording permission

### TTS not working

1. Verify API key is configured (for cloud providers)
2. Try macOS native provider to test
3. Check audio output is not muted
4. Try selecting a different output device

### Shortcuts not responding

1. Check Accessibility permission is granted
2. Look for conflicts with other applications
3. Reset shortcuts to defaults in Settings

### System Audio / App Audio not working

1. Grant Screen Recording permission in System Settings
2. For App Audio, ensure the target app is running
3. Refresh the app list from the audio source menu

### OCR not working

1. Grant Screen Recording permission in System Settings
2. Ensure the text in the selected region is clear and readable
3. Try selecting a larger region around the text

## Privacy & Security

- **API Keys**: Stored securely in macOS Keychain, never transmitted except to the respective provider
- **macOS Native**: Audio processed entirely on-device, no data sent externally
- **Local Whisper**: Audio processed entirely on-device, no data sent externally
- **Cloud Providers**: Audio sent to provider APIs (OpenAI, Google, ElevenLabs) for processing according to their privacy policies
- **No Telemetry**: SpeechDock does not collect or transmit usage data

## License

Apache License 2.0 - see [LICENSE](LICENSE) for details.

## Author

Yoichiro Hasebe

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

For developers: See [DEVELOPMENT_NOTES.md](DEVELOPMENT_NOTES.md) for build instructions and technical details.

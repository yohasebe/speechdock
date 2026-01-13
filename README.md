<p align="center">
  <img src="assets/logo.png" alt="TypeTalk Logo" width="128" height="128">
</p>

# TypeTalk

A macOS menu bar application for Speech-to-Text (STT) and Text-to-Speech (TTS) with support for multiple providers.

English | [日本語](README_ja.md)

## Features

### Speech-to-Text (STT)

Convert speech to text using:

| Provider | Models | API Key |
|----------|--------|---------|
| **macOS Native** | System Default | Not required |
| **Local Whisper** | Tiny, Base, Small, Medium, Large v2/v3, Large v3 Turbo | Not required |
| **OpenAI** | GPT-4o Transcribe, GPT-4o Mini Transcribe, Whisper | Required |
| **Google Gemini** | Gemini 2.5 Flash, Gemini 2.0 Flash, Gemini 1.5 Pro | Required |
| **ElevenLabs** | Scribe v2 Realtime | Required |

### Text-to-Speech (TTS)

Convert text to speech using:

| Provider | Models | API Key |
|----------|--------|---------|
| **macOS Native** | System Default | Not required |
| **OpenAI** | GPT-4o Mini TTS (Dec 2025), GPT-4o Mini TTS, TTS-1, TTS-1 HD | Required |
| **Google Gemini** | Gemini 2.5 Flash TTS, Gemini 2.5 Pro TTS | Required |
| **ElevenLabs** | Eleven v3, Flash v2.5, Multilingual v2, Turbo v2.5, Monolingual v1 | Required |

### Audio Sources

- **Microphone** - Record from any connected microphone with device selection
- **System Audio** - Capture all audio output from your Mac
- **App Audio** - Capture audio from a specific application

### Additional Features

- Global keyboard shortcuts for STT and TTS
- Customizable panel shortcuts with modifier key support
- Floating window for real-time transcription with paste target selection
- Floating window for TTS with text editing and word highlighting
- Audio output device selection for TTS
- Save synthesized audio to file (M4A/MP3 format)
- Language selection for STT and TTS
- Speed control for TTS playback
- Voice and model selection per provider
- Launch at login option

## Requirements

- macOS 14.0 (Sonoma) or later
- API keys for cloud providers (OpenAI, Google Gemini, or ElevenLabs)

## Installation

1. Download the latest `.dmg` file from the [Releases](https://github.com/yohasebe/TypeTalk/releases) page
2. Open the DMG file
3. Drag TypeTalk to your Applications folder
4. Launch TypeTalk from Applications

## Setup

### API Keys

To use cloud providers, you need to configure API keys:

1. Open **Settings** > **API Keys**
2. Enter your API keys:
   - **OpenAI**: [OpenAI Platform](https://platform.openai.com/api-keys)
   - **Google Gemini**: [Google AI Studio](https://aistudio.google.com/apikey)
   - **ElevenLabs**: [ElevenLabs Settings](https://elevenlabs.io/app/settings/api-keys)

API keys are securely stored in macOS Keychain.

### Permissions

TypeTalk requires the following permissions:

| Permission | Purpose |
|------------|---------|
| **Microphone** | Speech recognition input |
| **Accessibility** | Global keyboard shortcuts and text insertion |
| **Screen Recording** | Window thumbnails and System/App Audio capture |

Grant permissions in **System Settings** > **Privacy & Security**. TypeTalk will prompt you on first use.

## Usage

### Keyboard Shortcuts

| Action | Default Shortcut |
|--------|------------------|
| Start/Stop Recording (STT) | `Cmd + Shift + Space` |
| Read Selected Text (TTS) | `Ctrl + Option + T` |

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

Click the TypeTalk icon in the menu bar to:

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

- **General**: Select STT/TTS providers, models, voices, languages, and playback speed
- **Shortcuts**: Customize global hotkeys and panel shortcuts
- **API Keys**: Manage API keys for cloud providers

### Language Selection

Both STT and TTS support language selection:

- **Auto** (default): Automatically detects the language
- **Manual**: Choose from supported languages including English, Japanese, Chinese, Korean, Spanish, French, German, Italian, Portuguese, Russian, Arabic, and Hindi

### Launch at Login

Enable **Launch at Login** in **Settings** > **General** to start TypeTalk automatically.

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

## License

Apache License 2.0 - see [LICENSE](LICENSE) for details.

## Author

Yoichiro Hasebe

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

For developers: See [DEVELOPMENT_NOTES.md](DEVELOPMENT_NOTES.md) for build instructions and technical details.

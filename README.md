<p align="center">
  <img src="assets/logo.png" alt="TypeTalk Logo" width="128" height="128">
</p>

# TypeTalk

A macOS menu bar application for Speech-to-Text (STT) and Text-to-Speech (TTS) with support for multiple providers.

## Features

### Speech-to-Text (STT)

Convert speech to text using:

- **macOS Native** - Built-in Speech Recognition (no API key required)
- **OpenAI** - Whisper and GPT-4o Transcribe models
- **Google Gemini** - Gemini 2.5 Flash
- **ElevenLabs** - Scribe v2, Scribe v1

### Text-to-Speech (TTS)

Convert text to speech using:

- **macOS Native** - AVSpeechSynthesizer (no API key required)
- **OpenAI** - GPT-4o Mini TTS, TTS-1, TTS-1 HD
- **Google Gemini** - Gemini 2.5 Flash TTS, Gemini 2.5 Flash Lite TTS
- **ElevenLabs** - Eleven v3, Flash v2.5, Multilingual v2, Turbo v2.5

### Audio Input Sources

TypeTalk supports multiple audio input sources for STT:

- **Microphone** - Record from any connected microphone with device selection
- **System Audio** - Capture all audio output from your Mac
- **App Audio** - Capture audio from a specific application (e.g., browser, media player)

Audio input source can be changed from the menu bar or STT panel. System Audio and App Audio require Screen Recording permission.

### Additional Features

- Global keyboard shortcuts for STT and TTS
- Customizable panel shortcuts with modifier key support
- Menu bar interface with quick access to all features
- Floating window for real-time transcription display with window/app target selection
- Floating window for TTS with text editing and word highlighting
- Save synthesized audio to file (M4A/MP3 format)
- API key management via macOS Keychain
- Language selection for STT and TTS (Auto-detect or manual selection)
- Speed control for TTS playback
- Voice and model selection per provider
- Launch at login option
- Duplicate instance prevention

## Requirements

- macOS 14.0 (Sonoma) or later
- For cloud providers: API keys from OpenAI, Google Gemini, or ElevenLabs

## Installation

1. Download the latest `.dmg` file from the [Releases](https://github.com/yohasebe/TypeTalk/releases) page
2. Open the DMG file
3. Drag TypeTalk to your Applications folder
4. Launch TypeTalk from Applications
5. Grant necessary permissions when prompted (Microphone, Accessibility, Screen Recording)

## Usage

### Keyboard Shortcuts

| Action | Default Shortcut |
|--------|------------------|
| Start/Stop Recording (STT) | `Ctrl + Cmd + S` |
| Read Selected Text (TTS) | `Ctrl + Cmd + T` |

Shortcuts can be customized in Settings > Shortcuts.

### STT Panel Controls

| Action | Default Shortcut |
|--------|------------------|
| Record | `Cmd + R` |
| Stop Recording | `Cmd + S` |
| Paste Text | `Cmd + Return` |
| Select Target | `Cmd + Shift + Return` |
| Cancel | `Cmd + .` |

### TTS Panel Controls

| Action | Default Shortcut |
|--------|------------------|
| Speak | `Cmd + Return` |
| Stop | `Cmd + .` |
| Save Audio | `Cmd + S` |

All panel shortcuts can be customized in Settings > Shortcuts.

### Menu Bar

Click the TypeTalk icon in the menu bar to:

- Start/stop STT recording
- Open TTS panel
- Select audio input source and microphone device
- Access settings
- View current provider status

### Audio Input Selection

You can select the audio input source from:

1. **Menu Bar** - Click the audio source indicator to change between Microphone, System Audio, or App Audio
2. **STT Panel** - Use the "Input:" dropdown in the panel header

When Microphone is selected, you can also choose which microphone device to use if multiple are connected.

Note: App Audio selection is session-only and resets to Microphone when the app restarts.

## Configuration

### API Keys

1. Open Settings > API Keys
2. Enter your API keys for the providers you want to use:
   - **OpenAI**: Get your key from [OpenAI Platform](https://platform.openai.com/api-keys)
   - **Google Gemini**: Get your key from [Google AI Studio](https://aistudio.google.com/apikey)
   - **ElevenLabs**: Get your key from [ElevenLabs](https://elevenlabs.io/app/settings/api-keys)

API keys are securely stored in macOS Keychain.

### Settings

- **General**: Select STT/TTS providers, models, voices, languages, audio input source, and playback speed
- **Shortcuts**: Customize global hotkeys and panel-specific shortcuts (with modifier key support)
- **API Keys**: Manage API keys for cloud providers

### Language Selection

Both STT and TTS support language selection:

- **Auto (default)**: Automatically detects the language
- **Manual selection**: Choose from 12 languages including English, Japanese, Chinese, Korean, Spanish, French, German, Italian, Portuguese, Russian, Arabic, and Hindi

For STT, specifying a language can improve recognition accuracy. For TTS, language selection is available when using ElevenLabs provider.

### Launch at Login

Enable "Launch at Login" in Settings > General to automatically start TypeTalk when you log in.

## Permissions

TypeTalk requires the following permissions:

- **Microphone**: For speech recognition
- **Accessibility**: For global keyboard shortcuts and text insertion
- **Screen Recording**: For window thumbnails in paste target selection and system/app audio capture

Grant these permissions in System Settings > Privacy & Security. TypeTalk will prompt you on first launch if permissions are not yet granted.

## Troubleshooting

### STT not working

1. Ensure microphone permission is granted
2. Check that the selected provider has a valid API key (for cloud providers)
3. Try switching to macOS native provider to test
4. If using System Audio or App Audio, ensure Screen Recording permission is granted

### TTS not working

1. Check that the selected provider has a valid API key (for cloud providers)
2. Try switching to macOS native provider to test
3. Ensure audio output is not muted

### Keyboard shortcuts not responding

1. Ensure Accessibility permission is granted
2. Check for conflicts with other applications
3. Try resetting shortcuts to defaults in Settings

### System Audio / App Audio not working

1. Ensure Screen Recording permission is granted in System Settings > Privacy & Security > Screen Recording
2. For App Audio, make sure the target application is running and producing audio
3. Try refreshing the app list from the audio source menu

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Author

Yoichiro Hasebe

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

For developers: See [DEVELOPMENT_NOTES.md](DEVELOPMENT_NOTES.md) for build instructions, architecture details, and implementation notes.

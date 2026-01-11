# TypeTalk

A macOS menu bar application for Speech-to-Text (STT) and Text-to-Speech (TTS) with support for multiple providers.

## Features

### Speech-to-Text (STT)

Convert speech to text using:

- **macOS Native** - Built-in Speech Recognition (no API key required)
- **OpenAI** - Whisper and GPT-4o Transcribe models
- **Google Gemini** - Gemini 2.5 Flash
- **ElevenLabs** - Scribe v1

### Text-to-Speech (TTS)

Convert text to speech using:

- **macOS Native** - AVSpeechSynthesizer (no API key required)
- **OpenAI** - TTS-1, TTS-1 HD, GPT-4o Mini TTS
- **Google Gemini** - Gemini 2.5 Flash TTS
- **ElevenLabs** - Flash v2.5, Multilingual v2

### Additional Features

- Global keyboard shortcuts for STT and TTS
- Menu bar interface with quick access to all features
- Floating window for real-time transcription display
- Floating window for TTS with text editing
- API key management via macOS Keychain
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
5. Grant necessary permissions when prompted (Microphone, Accessibility)

## Usage

### Keyboard Shortcuts

| Action | Default Shortcut |
|--------|------------------|
| Start/Stop Recording (STT) | `Ctrl + Cmd + S` |
| Read Selected Text (TTS) | `Ctrl + Cmd + T` |

Shortcuts can be customized in Settings > Shortcuts.

### STT Panel Controls

| Action | Shortcut |
|--------|----------|
| Stop Recording | `Cmd + S` |
| Insert Text | `Cmd + Return` |
| Copy All | (click button) |
| Cancel | `Cmd + .` |

### TTS Panel Controls

| Action | Shortcut |
|--------|----------|
| Speak | `Cmd + Return` |
| Pause/Resume | `Cmd + P` |
| Stop | `Cmd + .` |
| Close | `Cmd + W` |

### Menu Bar

Click the TypeTalk icon in the menu bar to:

- Start/stop STT recording
- Open TTS panel
- Access settings
- View current provider status

## Configuration

### API Keys

1. Open Settings > API Keys
2. Enter your API keys for the providers you want to use:
   - **OpenAI**: Get your key from [OpenAI Platform](https://platform.openai.com/api-keys)
   - **Google Gemini**: Get your key from [Google AI Studio](https://aistudio.google.com/apikey)
   - **ElevenLabs**: Get your key from [ElevenLabs](https://elevenlabs.io/app/settings/api-keys)

API keys are securely stored in macOS Keychain.

### Environment Variables

Alternatively, you can set API keys as environment variables:

```bash
export OPENAI_API_KEY="your-openai-key"
export GEMINI_API_KEY="your-gemini-key"
export ELEVENLABS_API_KEY="your-elevenlabs-key"
```

### Settings

- **General**: Select STT/TTS providers, models, voices, and playback speed
- **Shortcuts**: Customize global keyboard shortcuts
- **API Keys**: Manage API keys for cloud providers

### Launch at Login

Enable "Launch at Login" in Settings > General to automatically start TypeTalk when you log in.

## Building from Source

### Prerequisites

- Xcode 15.0 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional, for project generation)

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

## Permissions

TypeTalk requires the following permissions:

- **Microphone**: For speech recognition
- **Accessibility**: For global keyboard shortcuts and text selection

Grant these permissions in System Settings > Privacy & Security.

## Troubleshooting

### STT not working

1. Ensure microphone permission is granted
2. Check that the selected provider has a valid API key (for cloud providers)
3. Try switching to macOS native provider to test

### TTS not working

1. Check that the selected provider has a valid API key (for cloud providers)
2. Try switching to macOS native provider to test
3. Ensure audio output is not muted

### Keyboard shortcuts not responding

1. Ensure Accessibility permission is granted
2. Check for conflicts with other applications
3. Try resetting shortcuts to defaults in Settings

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Author

Yoichiro Hasebe

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

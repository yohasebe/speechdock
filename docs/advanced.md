# SpeechDock — Advanced Features

This page covers features that require API keys from cloud providers. These are optional enhancements — SpeechDock works fully with macOS native STT/TTS without any API keys.

## API Key Setup

To use cloud providers, configure API keys in **Settings** > **API Keys**:

| Provider | Get API Key | Environment Variable |
|----------|-------------|---------------------|
| **OpenAI** | [OpenAI Platform](https://platform.openai.com/api-keys) | `OPENAI_API_KEY` |
| **Google Gemini** | [Google AI Studio](https://aistudio.google.com/apikey) | `GEMINI_API_KEY` |
| **ElevenLabs** | [ElevenLabs Settings](https://elevenlabs.io/app/settings/api-keys) | `ELEVENLABS_API_KEY` |
| **Grok (xAI)** | [xAI Console](https://console.x.ai/) | `GROK_API_KEY` |

API keys are securely stored in macOS Keychain. Alternatively, you can set environment variables for development.

## Cloud STT Providers

Cloud providers offer higher accuracy, more language support, and specialized features compared to macOS native STT.

| Provider | Models | Features |
|----------|--------|----------|
| **OpenAI** | GPT-4o Transcribe, GPT-4o Mini Transcribe, Whisper | High accuracy, 100+ languages |
| **Google Gemini** | Gemini 2.5 Flash, Gemini 2.0 Flash, Gemini 1.5 Pro | Multimodal, fast |
| **ElevenLabs** | Scribe v2 Realtime | Low latency, natural punctuation |
| **Grok** | Grok Realtime | xAI's realtime transcription |

Select the provider in **Settings** > **General** or from the menu bar.

## Cloud TTS Providers

Cloud TTS provides natural-sounding voices with various styles and languages.

| Provider | Models | Voices |
|----------|--------|--------|
| **OpenAI** | GPT-4o Mini TTS, TTS-1, TTS-1 HD | Multiple natural voices |
| **Google Gemini** | Gemini 2.5 Flash TTS, Gemini 2.5 Pro TTS | Multilingual voices |
| **ElevenLabs** | Eleven v3, Flash v2.5, Multilingual v2, Turbo v2.5, Monolingual v1 | Large voice library |
| **Grok** | Grok Voice | 5 distinct voices |

### Voice and Model Selection

Each provider offers different voices and models. Select them in:
- **Settings** > **General** (persistent setting)
- **TTS Panel** header (quick switch)
- **Menu Bar** (quick switch)

### Audio Output Device

Route TTS playback to any audio output device (speakers, headphones, virtual devices). Select in Settings, menu bar, or the TTS panel.

## Audio File Transcription

Transcribe pre-recorded audio files using cloud STT providers. Not available with macOS native or Grok providers.

| Provider | Formats | Max Size | Max Duration | API |
|----------|---------|----------|--------------|-----|
| **OpenAI** | MP3, WAV, M4A, FLAC, WebM, MP4 | 25 MB | Unlimited | Whisper |
| **Gemini** | MP3, WAV, AAC, OGG, FLAC | 20 MB | ~10 min | generateContent |
| **ElevenLabs** | MP3, WAV, M4A, OGG, FLAC | 25 MB | ~2 hours | Scribe v2 |

### How to Transcribe

**Drag & Drop**: Drag an audio file onto the STT panel's text area.

**Menu Bar**: Select **Transcribe Audio File...** from the SpeechDock menu bar.

The STT panel placeholder displays the supported formats and limits for the currently selected provider.

## Translation with External Providers

While macOS on-device translation supports ~18 languages, cloud providers offer:
- 25+ languages (all languages in the language list)
- Higher translation quality using LLMs
- Works on macOS 14+ (no macOS 26 requirement)

### Translation Providers and Models

| Provider | Models | Notes |
|----------|--------|-------|
| **macOS** (default) | System | On-device, no API key, macOS 26+ |
| **OpenAI** | GPT-5 Nano (default), GPT-5 Mini, GPT-5.2 | Fast, high quality |
| **Gemini** | Gemini 3 Flash (default), Gemini 3 Pro | Fast, multilingual |
| **Grok** | Grok 3 Fast (default), Grok 3 Mini Fast | Fast translation |

### Switching Translation Provider

- **Settings** > **General** > **Translation**: Set the default provider and model
- **Panel**: Click the `⚡` button next to the translation controls for quick switching

### Provider Auto-Sync

When you switch STT or TTS providers, the translation provider automatically syncs:

| STT/TTS Provider | Translation Provider |
|------------------|---------------------|
| OpenAI | OpenAI |
| Gemini | Gemini |
| Grok | Grok |
| ElevenLabs / macOS | macOS |

## Language Selection

Both STT and TTS support language selection with all cloud providers:

- **Auto** (default): Automatically detects the spoken/target language
- **Manual**: Choose from 25+ supported languages

Available languages: English, Japanese, Chinese, Korean, Spanish, French, German, Italian, Portuguese, Russian, Arabic, Hindi, Dutch, Polish, Turkish, Indonesian, Vietnamese, Thai, Bengali, Gujarati, Kannada, Malayalam, Marathi, Tamil, Telugu.

## TTS Speed Control (Save Audio)

When saving audio to a file, speed is controlled differently from real-time playback:

| Provider | Parameter | Range | Notes |
|----------|-----------|-------|-------|
| OpenAI | `speed` | 0.25–4.0 | TTS-1/TTS-1 HD only |
| ElevenLabs | `voice_settings.speed` | 0.7–1.2 | Mapped from app range |
| Gemini | Text instruction | N/A | Natural language pace instruction |
| macOS | Words per minute | 50–500 | Based on 175 wpm baseline |
| Grok | — | — | Speed parameter not supported |

For real-time playback, speed is always controlled locally via audio processing, allowing dynamic adjustment during playback.

## Privacy Considerations

When using cloud providers:
- Audio data is sent to the respective provider's API for processing
- Each provider has its own privacy policy and data retention rules
- For maximum privacy, use macOS native providers (all processing on-device)
- API keys are stored in macOS Keychain and never shared between providers

---

**Previous**: [Basic Features](index.md)
| **Next**: [AppleScript Automation](applescript.md)

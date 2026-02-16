---
layout: default
title: Home
nav_order: 1
---

<p align="right"><a href="index_ja.html">日本語</a></p>

<p align="center">
  <img src="images/icon.png" alt="SpeechDock" width="128" height="128">
</p>

# SpeechDock
{: .text-center }

**Any sound to text. Any text to speech. From your menu bar.**
{: .text-center .fs-6 }

[Download](https://github.com/yohasebe/SpeechDock/releases){: .btn .btn-primary .mr-2 }
[View on GitHub](https://github.com/yohasebe/SpeechDock){: .btn }
{: .text-center }

---

## What is SpeechDock?

**Hear any text on your screen** — Selected text, typed text, pasted content, or text captured via OCR from any screen region. If you can see it, SpeechDock can read it aloud.

**Transcribe any audio on your Mac** — Your voice through the microphone, system-wide audio, or sound from a specific app. If your Mac can hear it, SpeechDock can turn it into text in real time.

A menu bar app that makes STT and TTS accessible from anywhere on your Mac with global hotkeys. Works immediately after installation — no API keys or additional downloads required.

---

## Key Features

### Speech-to-Text (STT)
- **Any audio source** — Microphone, System Audio, or specific App Audio
- **Real-time transcription** — See text as you speak
- **Subtitle mode** — Floating overlay for presentations and meetings
- **Quick transcription** — Floating mic button for instant dictation

### Text-to-Speech (TTS)
- **Any text source** — Type, paste, select in other apps, or OCR from screen
- **Natural voices** — Use macOS built-in or cloud provider voices
- **Speed control** — Adjust playback speed in real-time (0.5x to 2.0x)
- **Save audio** — Export speech to audio files

### Translation
- **On-device translation** — No API keys required (macOS 26+)
- **18+ languages** — Translate between major languages
- **TTS integration** — Automatically read translated text

### Cloud Providers (Optional)
- **OpenAI** — GPT-4o Transcribe, GPT-4o Mini TTS
- **Google Gemini** — Gemini 2.5 Flash (STT/TTS)
- **ElevenLabs** — Scribe v2 (STT), Eleven v3 (TTS)
- **Grok (xAI)** — Grok 2 (STT/TTS)

---

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac (M1/M2/M3/M4)

---

## Documentation

| Page | Description |
|:-----|:------------|
| [Basic Features](basics.html) | Installation, STT, TTS, OCR, Subtitles, Shortcuts |
| [Advanced Features](advanced.html) | Cloud providers, API keys, File transcription |
| [AppleScript](applescript.html) | Automation and scripting |

---

## Screenshots

<figure>
  <img src="images/stt-panel.png" alt="STT Panel" style="max-width: 600px;">
  <figcaption>Speech-to-Text Panel</figcaption>
</figure>

<figure>
  <img src="images/tts-panel.png" alt="TTS Panel" style="max-width: 600px;">
  <figcaption>Text-to-Speech Panel</figcaption>
</figure>

<figure>
  <img src="images/quick-transcription.png" alt="Quick Transcription" style="max-width: 600px;">
  <figcaption>Quick Transcription — Floating mic button with real-time HUD</figcaption>
</figure>

<figure>
  <img src="images/subtitle-overlay.png" alt="Subtitle Mode" style="max-width: 100%;">
  <figcaption>Subtitle Mode — Real-time transcription as floating subtitles</figcaption>
</figure>

---

## License

SpeechDock is released under the [Apache License 2.0](https://github.com/yohasebe/SpeechDock/blob/main/LICENSE).

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-01-11

### Added
- Initial release of TypeTalk
- **Speech-to-Text (STT)** support with multiple providers:
  - macOS native (Speech Recognition)
  - OpenAI (Whisper, GPT-4o Transcribe)
  - Google Gemini (2.5 Flash)
  - ElevenLabs (Scribe v1)
- **Text-to-Speech (TTS)** support with multiple providers:
  - macOS native (AVSpeechSynthesizer)
  - OpenAI (TTS-1, TTS-1 HD, GPT-4o Mini TTS)
  - Google Gemini (2.5 Flash TTS)
  - ElevenLabs (Flash v2.5, Multilingual v2)
- Global keyboard shortcuts for STT and TTS
- Menu bar interface with quick access to all features
- Floating window for real-time transcription display
- Floating window for TTS with text editing
- API key management via macOS Keychain
- Speed control for TTS playback
- Voice and model selection per provider
- Launch at login option
- Duplicate instance prevention

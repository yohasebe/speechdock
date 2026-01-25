# SpeechDock — AppleScript Automation

SpeechDock exposes its TTS, STT, and translation features via AppleScript, enabling automation from Script Editor, Automator, Shortcuts, and other scriptable applications.

## Getting Started

1. Launch SpeechDock (it must be running in the menu bar)
2. Open **Script Editor** (Applications > Utilities > Script Editor)
3. Verify the dictionary: **File** > **Open Dictionary...** > Select **SpeechDock**

All commands are sent via `tell application "SpeechDock"`.

## Commands

### speak text

Speak the given text using the current TTS provider and voice. Does not open the TTS panel.

```applescript
tell application "SpeechDock"
    speak text "Hello, world!"
end tell
```

### stop speaking

Stop the current TTS playback.

```applescript
tell application "SpeechDock"
    stop speaking
end tell
```

### pause speaking

Pause the current TTS playback. Returns error 1011 if not currently speaking.

```applescript
tell application "SpeechDock"
    pause speaking
end tell
```

### resume speaking

Resume paused TTS playback. Returns error 1012 if not currently paused.

```applescript
tell application "SpeechDock"
    resume speaking
end tell
```

### save audio

Synthesize text to an audio file. Returns the saved file path on success.

```applescript
tell application "SpeechDock"
    set savedPath to save audio "This is a test sentence for audio synthesis." to file "/tmp/output.mp3"
end tell
```

- Text must be at least 5 characters
- The parent directory must exist
- File format depends on the TTS provider (typically MP3 or M4A)
- This command blocks until synthesis is complete

### translate

Translate text to the specified language. Returns the translated text.

```applescript
tell application "SpeechDock"
    set result to translate "Good morning, how are you?" to "Japanese"
    -- result: "おはようございます、お元気ですか？"
end tell
```

- Language names are case-insensitive
- Accepts English names (e.g., "Japanese") or native names (e.g., "日本語")
- Uses the currently selected translation provider
- This command blocks until translation is complete

**Supported languages**: English, Japanese, Chinese, Korean, Spanish, French, German, Italian, Portuguese, Russian, Arabic, Hindi, Dutch, Polish, Turkish, Indonesian, Vietnamese, Thai, Bengali, Gujarati, Kannada, Malayalam, Marathi, Tamil, Telugu.

### transcribe file

Transcribe an audio file to text. Returns the transcribed text.

```applescript
tell application "SpeechDock"
    set result to transcribe file "/path/to/recording.mp3"
end tell
```

- Requires a cloud STT provider (OpenAI, Gemini, or ElevenLabs)
- macOS native and Grok providers do not support file transcription
- See [Advanced Features](advanced.md#audio-file-transcription) for supported formats and limits
- This command blocks until transcription is complete

### copy to clipboard

Copy the given text to the system clipboard.

```applescript
tell application "SpeechDock"
    copy to clipboard "Text to copy"
end tell
```

### paste text

Paste the given text into the frontmost application (simulates Cmd+V).

```applescript
tell application "SpeechDock"
    paste text "Text to paste into the active app"
end tell
```

- This command blocks until the paste operation completes
- Requires Accessibility permission

### shortcuts

Display the keyboard shortcuts cheat sheet panel.

```applescript
tell application "SpeechDock"
    shortcuts
end tell
```

The panel shows all available keyboard shortcuts and can be dismissed by clicking outside or pressing Escape.

### start quick transcription

Start quick transcription using the floating mic button. Shows the button if hidden.

```applescript
tell application "SpeechDock"
    start quick transcription
end tell
```

Returns error 1024 if already recording.

### stop quick transcription

Stop quick transcription and return the transcribed text.

```applescript
tell application "SpeechDock"
    set result to stop quick transcription
    -- result contains the transcribed text
end tell
```

Returns the transcribed text, or empty if nothing was transcribed. Returns error if not currently recording.

### toggle quick transcription

Toggle quick transcription recording on/off.

```applescript
tell application "SpeechDock"
    toggle quick transcription
end tell
```

If not recording, starts recording. If recording, stops and pastes the transcribed text.

## Properties

Read and write application settings via properties on the `application` object.

### tts provider (read/write)

The current TTS provider. Valid values: `"macOS"`, `"OpenAI"`, `"Gemini"`, `"ElevenLabs"`, `"Grok"`.

```applescript
tell application "SpeechDock"
    set tts provider to "OpenAI"
    get tts provider
    -- "OpenAI"
end tell
```

Setting an invalid value is silently ignored.

### tts voice (read/write)

The current TTS voice name.

```applescript
tell application "SpeechDock"
    set tts voice to "alloy"
    get tts voice
end tell
```

### tts speed (read/write)

TTS playback speed (0.25 to 4.0, default 1.0). Values outside this range are clamped.

```applescript
tell application "SpeechDock"
    set tts speed to 1.5
    get tts speed
    -- 1.5
end tell
```

### stt provider (read/write)

The current STT provider. Valid values: `"macOS"`, `"OpenAI"`, `"Gemini"`, `"ElevenLabs"`, `"Grok"`.

```applescript
tell application "SpeechDock"
    set stt provider to "Gemini"
end tell
```

### translation provider (read/write)

The current translation provider. Valid values: `"macOS"`, `"OpenAI"`, `"Gemini"`, `"Grok"`.

```applescript
tell application "SpeechDock"
    set translation provider to "OpenAI"
end tell
```

### is speaking (read-only)

Whether TTS is currently speaking or paused.

```applescript
tell application "SpeechDock"
    if is speaking then
        stop speaking
    end if
end tell
```

### is recording (read-only)

Whether STT is currently recording.

```applescript
tell application "SpeechDock"
    get is recording
    -- false
end tell
```

### quick transcription visible (read/write)

Whether the floating mic button for quick transcription is visible.

```applescript
tell application "SpeechDock"
    set quick transcription visible to true  -- show button
    get quick transcription visible
    -- true
end tell
```

## Examples

### Translate and speak

```applescript
tell application "SpeechDock"
    set tts provider to "OpenAI"
    set tts speed to 0.9
    set translation provider to "OpenAI"

    set translated to translate "The weather is beautiful today." to "French"
    speak text translated
end tell
```

### Batch translate to multiple languages

```applescript
tell application "SpeechDock"
    set sourceText to "Hello, welcome to SpeechDock!"
    set languages to {"Japanese", "French", "German", "Spanish"}

    repeat with lang in languages
        set result to translate sourceText to lang
        log lang & ": " & result
    end repeat
end tell
```

### Transcribe and translate

```applescript
tell application "SpeechDock"
    set stt provider to "OpenAI"
    set translation provider to "OpenAI"

    set transcription to transcribe file "/path/to/meeting.mp3"
    set translated to translate transcription to "English"

    copy to clipboard translated
end tell
```

### Save audio in multiple speeds

```applescript
tell application "SpeechDock"
    set tts provider to "OpenAI"
    set tts voice to "nova"

    set speeds to {0.8, 1.0, 1.2, 1.5}
    set textToSpeak to "This is a speed comparison test for text to speech."

    repeat with spd in speeds
        set tts speed to spd
        save audio textToSpeak to file ("/tmp/speed_" & spd & ".mp3")
    end repeat
end tell
```

### Error handling

```applescript
tell application "SpeechDock"
    try
        set result to transcribe file "/nonexistent/file.mp3"
    on error errMsg number errNum
        if errNum is 1021 then
            display dialog "File not found: " & errMsg
        else if errNum is 1020 then
            display dialog "Provider doesn't support file transcription. Switch to OpenAI, Gemini, or ElevenLabs."
        else
            display dialog "Error " & errNum & ": " & errMsg
        end if
    end try
end tell
```

### Check state before acting

```applescript
tell application "SpeechDock"
    if is speaking then
        stop speaking
        delay 0.5
    end if

    if is recording then
        display dialog "Recording in progress. Cannot transcribe file."
    else
        set result to transcribe file "/path/to/audio.mp3"
        speak text result
    end if
end tell
```

### Quick transcription workflow

```applescript
tell application "SpeechDock"
    -- Show the floating mic button
    set quick transcription visible to true

    -- Start recording
    start quick transcription

    -- Wait for user to finish speaking (or use a timer)
    delay 5

    -- Stop and get the transcribed text
    set transcribedText to stop quick transcription

    -- Translate and speak the result
    if transcribedText is not "" then
        set translated to translate transcribedText to "Japanese"
        speak text translated
    end if
end tell
```

## Error Codes

All errors include a human-readable message explaining the issue and how to fix it.

### General (1000–1009)

| Code | Description |
|------|-------------|
| 1000 | Internal error |
| 1001 | Invalid parameter |

### TTS (1010–1019)

| Code | Description |
|------|-------------|
| 1010 | Empty text provided |
| 1011 | Not currently speaking (cannot pause) |
| 1012 | Not currently paused (cannot resume) |
| 1013 | Already speaking |
| 1014 | TTS provider error |
| 1015 | Save path is invalid |
| 1016 | Save directory does not exist |
| 1017 | Save operation failed |
| 1018 | Text too short (min 5 characters for save) |

### STT (1020–1029)

| Code | Description |
|------|-------------|
| 1020 | Provider does not support file transcription |
| 1021 | Audio file not found |
| 1022 | Unsupported audio format |
| 1023 | File too large for provider |
| 1024 | Already recording (cannot transcribe file) |
| 1025 | Transcription failed |
| 1026 | Not currently recording (cannot stop) |

### Translation (1030–1039)

| Code | Description |
|------|-------------|
| 1030 | Empty text provided |
| 1031 | Invalid or unknown language name |
| 1032 | Translation failed |
| 1033 | Translation provider unavailable (macOS 26+ required) |

### Provider/Settings (1040–1049)

| Code | Description |
|------|-------------|
| 1040 | Invalid provider name |
| 1042 | Invalid speed value (must be 0.25–4.0) |
| 1043 | API key not configured (message includes the env var name) |

### Clipboard (1050–1059)

| Code | Description |
|------|-------------|
| 1050 | Empty text provided |
| 1051 | Paste operation failed |

## Notes

- **Headless operation**: Commands like `speak text` and `save audio` work without opening any panel.
- **Blocking commands**: `save audio`, `translate`, `transcribe file`, and `paste text` block the AppleScript caller until completion.
- **Provider persistence**: Setting a provider via AppleScript persists across sessions (same as changing in Settings).
- **API keys**: Ensure API keys are configured before using cloud provider commands. Error 1043 will indicate which environment variable to set.

---

**Previous**: [Advanced Features](advanced.md)

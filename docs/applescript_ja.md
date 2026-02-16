---
layout: default
title: AppleScript
nav_exclude: true
search_exclude: true
lang: ja
---

<p align="right"><a href="applescript.html">English</a></p>

# SpeechDock — AppleScript自動化

SpeechDockはTTS、STT、翻訳機能をAppleScript経由で公開しており、Script Editor、Automator、ショートカット、その他のスクリプト対応アプリケーションからの自動化が可能です。

## はじめに

1. SpeechDockを起動します（メニューバーで実行中である必要があります）
2. **Script Editor**を開きます（アプリケーション > ユーティリティ > Script Editor）
3. 用語説明を確認します：**ファイル** > **用語説明を開く...** > **SpeechDock**を選択

すべてのコマンドは `tell application "SpeechDock"` を通じて送信します。

## コマンド

### speak text

指定されたテキストを現在のTTSプロバイダと音声で読み上げます。TTSパネルは開きません。

```applescript
tell application "SpeechDock"
    speak text "Hello, world!"
end tell
```

### stop speaking

現在のTTS再生を停止します。

```applescript
tell application "SpeechDock"
    stop speaking
end tell
```

### pause speaking

現在のTTS再生を一時停止します。現在読み上げ中でない場合はエラー1011を返します。

```applescript
tell application "SpeechDock"
    pause speaking
end tell
```

### resume speaking

一時停止中のTTS再生を再開します。現在一時停止中でない場合はエラー1012を返します。

```applescript
tell application "SpeechDock"
    resume speaking
end tell
```

### save audio

テキストを音声ファイルに合成します。成功時は保存されたファイルパスを返します。

```applescript
tell application "SpeechDock"
    set savedPath to save audio "This is a test sentence for audio synthesis." to file "/tmp/output.mp3"
end tell
```

- テキストは5文字以上である必要があります
- 親ディレクトリが存在する必要があります
- ファイル形式はTTSプロバイダによって異なります（通常はMP3またはM4A）
- このコマンドは合成が完了するまでブロックします

### translate

テキストを指定された言語に翻訳します。翻訳されたテキストを返します。

```applescript
tell application "SpeechDock"
    set result to translate "Good morning, how are you?" to "Japanese"
    -- result: "おはようございます、お元気ですか？"
end tell
```

- 言語名は大文字小文字を区別しません
- 英語名（例：「Japanese」）またはネイティブ名（例：「日本語」）を受け付けます
- 現在選択されている翻訳プロバイダを使用します
- このコマンドは翻訳が完了するまでブロックします

**対応言語**: English、Japanese、Chinese、Korean、Spanish、French、German、Italian、Portuguese、Russian、Arabic、Hindi、Dutch、Polish、Turkish、Indonesian、Vietnamese、Thai、Bengali、Gujarati、Kannada、Malayalam、Marathi、Tamil、Telugu

### transcribe file

音声ファイルをテキストに文字起こしします。文字起こしされたテキストを返します。

```applescript
tell application "SpeechDock"
    set result to transcribe file "/path/to/recording.mp3"
end tell
```

- 対応STTプロバイダ（OpenAI、Gemini、ElevenLabs、またはmacOS 26+）が必要です
- Grokプロバイダはファイル文字起こしに対応していません
- 対応形式と制限については[高度な機能](advanced_ja.md#音声ファイルの文字起こし)を参照してください
- このコマンドは文字起こしが完了するまでブロックします

### copy to clipboard

指定されたテキストをシステムクリップボードにコピーします。

```applescript
tell application "SpeechDock"
    copy to clipboard "Text to copy"
end tell
```

### paste text

指定されたテキストを最前面のアプリケーションにペーストします（Cmd+Vをシミュレート）。

```applescript
tell application "SpeechDock"
    paste text "Text to paste into the active app"
end tell
```

- このコマンドはペースト操作が完了するまでブロックします
- アクセシビリティ権限が必要です

### show shortcuts

キーボードショートカットのチートシートパネルを表示します。

```applescript
tell application "SpeechDock"
    show shortcuts
end tell
```

パネルには利用可能なすべてのキーボードショートカットが表示され、外側をクリックするかEscapeキーを押すと閉じることができます。

### start quick transcription

フローティングマイクボタンを使用してクイック文字起こしを開始します。非表示の場合はボタンを表示します。

```applescript
tell application "SpeechDock"
    start quick transcription
end tell
```

すでに録音中の場合はエラー1024を返します。

### stop quick transcription

クイック文字起こしを停止し、文字起こしされたテキストを返します。

```applescript
tell application "SpeechDock"
    set result to stop quick transcription
    -- resultには文字起こしされたテキストが含まれます
end tell
```

文字起こしされたテキストを返します。何も文字起こしされていない場合は空を返します。現在録音中でない場合はエラーを返します。

### toggle quick transcription

クイック文字起こしの録音のオン/オフを切り替えます。

```applescript
tell application "SpeechDock"
    toggle quick transcription
end tell
```

録音中でない場合は録音を開始します。録音中の場合は停止して文字起こしされたテキストをペーストします。

## プロパティ

`application`オブジェクトのプロパティを通じてアプリケーション設定の読み取りと書き込みができます。

### tts provider（読み取り/書き込み）

現在のTTSプロバイダ。有効な値：`"macOS"`、`"OpenAI"`、`"Gemini"`、`"ElevenLabs"`、`"Grok"`

```applescript
tell application "SpeechDock"
    set tts provider to "OpenAI"
    get tts provider
    -- "OpenAI"
end tell
```

無効な値を設定すると、警告なく無視されます。

### tts voice（読み取り/書き込み）

現在のTTS音声名。

```applescript
tell application "SpeechDock"
    set tts voice to "alloy"
    get tts voice
end tell
```

### tts speed（読み取り/書き込み）

TTS再生速度（0.25〜4.0、デフォルト1.0）。この範囲外の値はクランプされます。

```applescript
tell application "SpeechDock"
    set tts speed to 1.5
    get tts speed
    -- 1.5
end tell
```

### stt provider（読み取り/書き込み）

現在のSTTプロバイダ。有効な値：`"macOS"`、`"OpenAI"`、`"Gemini"`、`"ElevenLabs"`、`"Grok"`

```applescript
tell application "SpeechDock"
    set stt provider to "Gemini"
end tell
```

### translation provider（読み取り/書き込み）

現在の翻訳プロバイダ。有効な値：`"macOS"`、`"OpenAI"`、`"Gemini"`、`"Grok"`

```applescript
tell application "SpeechDock"
    set translation provider to "OpenAI"
end tell
```

### is speaking（読み取り専用）

TTSが現在読み上げ中または一時停止中かどうか。

```applescript
tell application "SpeechDock"
    if is speaking then
        stop speaking
    end if
end tell
```

### is recording（読み取り専用）

STTが現在録音中かどうか。

```applescript
tell application "SpeechDock"
    get is recording
    -- false
end tell
```

### quick transcription visible（読み取り/書き込み）

クイック文字起こし用のフローティングマイクボタンが表示されているかどうか。

```applescript
tell application "SpeechDock"
    set quick transcription visible to true  -- ボタンを表示
    get quick transcription visible
    -- true
end tell
```

## 使用例

### 翻訳して読み上げる

```applescript
tell application "SpeechDock"
    set tts provider to "OpenAI"
    set tts speed to 0.9
    set translation provider to "OpenAI"

    set translated to translate "The weather is beautiful today." to "French"
    speak text translated
end tell
```

### 複数言語にバッチ翻訳

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

### 文字起こしして翻訳

```applescript
tell application "SpeechDock"
    set stt provider to "OpenAI"
    set translation provider to "OpenAI"

    set transcription to transcribe file "/path/to/meeting.mp3"
    set translated to translate transcription to "English"

    copy to clipboard translated
end tell
```

### 複数の速度で音声を保存

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

### エラー処理

```applescript
tell application "SpeechDock"
    try
        set result to transcribe file "/nonexistent/file.mp3"
    on error errMsg number errNum
        if errNum is 1021 then
            display dialog "ファイルが見つかりません: " & errMsg
        else if errNum is 1020 then
            display dialog "このプロバイダはファイル文字起こしに対応していません。OpenAI、Gemini、またはElevenLabsに切り替えてください。"
        else
            display dialog "エラー " & errNum & ": " & errMsg
        end if
    end try
end tell
```

### 操作前に状態を確認

```applescript
tell application "SpeechDock"
    if is speaking then
        stop speaking
        delay 0.5
    end if

    if is recording then
        display dialog "録音中です。ファイル文字起こしはできません。"
    else
        set result to transcribe file "/path/to/audio.mp3"
        speak text result
    end if
end tell
```

### クイック文字起こしワークフロー

```applescript
tell application "SpeechDock"
    -- フローティングマイクボタンを表示
    set quick transcription visible to true

    -- 録音を開始
    start quick transcription

    -- ユーザーが話し終わるのを待つ（またはタイマーを使用）
    delay 5

    -- 停止して文字起こしされたテキストを取得
    set transcribedText to stop quick transcription

    -- 結果を翻訳して読み上げ
    if transcribedText is not "" then
        set translated to translate transcribedText to "Japanese"
        speak text translated
    end if
end tell
```

## エラーコード

すべてのエラーには、問題と解決方法を説明する人間が読めるメッセージが含まれています。

### 一般（1000〜1009）

| コード | 説明 |
|------|-------------|
| 1000 | 内部エラー |
| 1001 | 無効なパラメータ |

### TTS（1010〜1019）

| コード | 説明 |
|------|-------------|
| 1010 | 空のテキストが指定されました |
| 1011 | 現在読み上げ中ではありません（一時停止できません） |
| 1012 | 現在一時停止中ではありません（再開できません） |
| 1013 | すでに読み上げ中です |
| 1014 | TTSプロバイダエラー |
| 1015 | 保存パスが無効です |
| 1016 | 保存ディレクトリが存在しません |
| 1017 | 保存操作に失敗しました |
| 1018 | テキストが短すぎます（保存には最低5文字必要） |

### STT（1020〜1029）

| コード | 説明 |
|------|-------------|
| 1020 | このプロバイダはファイル文字起こしに対応していません |
| 1021 | 音声ファイルが見つかりません |
| 1022 | サポートされていない音声形式 |
| 1023 | ファイルがプロバイダの制限を超えています |
| 1024 | すでに録音中です（ファイル文字起こしできません） |
| 1025 | 文字起こしに失敗しました |
| 1026 | 現在録音中ではありません（停止できません） |

### 翻訳（1030〜1039）

| コード | 説明 |
|------|-------------|
| 1030 | 空のテキストが指定されました |
| 1031 | 無効または不明な言語名 |
| 1032 | 翻訳に失敗しました |
| 1033 | 翻訳プロバイダが利用できません（macOS 26以降が必要） |

### プロバイダ/設定（1040〜1049）

| コード | 説明 |
|------|-------------|
| 1040 | 無効なプロバイダ名 |
| 1042 | 無効な速度値（0.25〜4.0である必要があります） |
| 1043 | APIキーが設定されていません（メッセージには環境変数名が含まれます） |

### クリップボード（1050〜1059）

| コード | 説明 |
|------|-------------|
| 1050 | 空のテキストが指定されました |
| 1051 | ペースト操作に失敗しました |

## 注意事項

- **ヘッドレス操作**: `speak text`や`save audio`などのコマンドはパネルを開かずに動作します。
- **ブロッキングコマンド**: `save audio`、`translate`、`transcribe file`、`paste text`は完了するまでAppleScriptの呼び出し元をブロックします。
- **プロバイダの永続化**: AppleScript経由でプロバイダを設定すると、セッション間で永続化されます（設定で変更するのと同じ）。
- **APIキー**: クラウドプロバイダのコマンドを使用する前に、APIキーが設定されていることを確認してください。エラー1043は設定すべき環境変数を示します。

---

**前へ**: [高度な機能](advanced_ja.md)

# SpeechDock - Project Context for Claude Code

## プロジェクト概要

macOS メニューバー常駐型の音声認識（STT）・音声合成（TTS）アプリケーション。複数のプロバイダに対応し、マイク音声、システム音声、アプリ音声の文字起こし、およびテキスト読み上げ機能を提供。

**名前変更履歴**: TypeTalk → SpeechDock (2026-01-20)

## 技術スタック

- **言語**: Swift 5.9+
- **UI**: SwiftUI + AppKit (NSWindow, NSPanel)
- **最小OS**: macOS 14.0 (Sonoma)
- **アーキテクチャ**: Apple Silicon (M1/M2/M3/M4)
- **ビルド**: XcodeGen (project.yml → .xcodeproj)
- **自動更新**: Sparkle 2

## 主要コンポーネント

### STTプロバイダ (`Services/RealtimeSTT/`)
| プロバイダ | ファイル | 特徴 |
|-----------|---------|------|
| macOS Native | `MacOSRealtimeSTT.swift` | SFSpeechRecognizer使用、60秒制限を自動リスタートで回避 |
| SpeechAnalyzer | `SpeechAnalyzerSTT.swift` | macOS 26+専用、時間制限なし |
| OpenAI | `OpenAIRealtimeSTT.swift` | Realtime API、WebSocket |
| Gemini | `GeminiRealtimeSTT.swift` | Live API、WebSocket |
| ElevenLabs | `ElevenLabsRealtimeSTT.swift` | Scribe v2 |
| Grok | `GrokRealtimeSTT.swift` | xAI Realtime API |

### TTSプロバイダ (`Services/TTS/`)
- `MacOSTTS.swift` - AVSpeechSynthesizer
- `OpenAITTS.swift` - TTS-1, TTS-1 HD, GPT-4o Mini TTS
- `GeminiTTS.swift` - Gemini 2.5 Flash/Pro TTS
- `ElevenLabsTTS.swift` - 複数モデル対応
- `GrokTTS.swift` - Grok Voice

### 翻訳プロバイダ (`Services/Translation/`)
| プロバイダ | ファイル | 特徴 |
|-----------|---------|------|
| macOS | `MacOSTranslation.swift` | オンデバイス、APIキー不要、macOS 26+ |
| OpenAI | `LLMTranslation.swift` | GPT-4o-mini、高品質 |
| Gemini | `LLMTranslation.swift` | Gemini 2.0 Flash、高品質 |
| Grok | `LLMTranslation.swift` | Grok 3 Fast、高品質 |

**プロバイダ選択ロジック**:
1. macOS Translation (macOS 26+、対応言語の場合)
2. OpenAI (APIキーがある場合)
3. Gemini (APIキーがある場合)
4. Grok (APIキーがある場合)

### ウィンドウ管理
- `FloatingWindowManager.swift` - STT/TTSパネル管理（排他制御）
- `SubtitleOverlayManager.swift` - 字幕オーバーレイ（クリックスルー）
- `WindowLevelCoordinator.swift` - ウィンドウレベル調整

### 状態管理
- `AppState.swift` - @Observable、シングルトン、全設定の保存/読み込み

## 過去に解決した問題

### Grok STT テキスト重複 (2026-01-20)
**問題**: conversation.item.added イベントがユーザー入力とGrokレスポンスの両方で発火し、テキストが重複
**解決**: `response.output_item.added` イベントを追跡し、次の `conversation.item.added` がレスポンスアイテムの場合はスキップ
```swift
case "response.output_item.added":
    isNextItemFromResponse = true
case "conversation.item.added":
    if isNextItemFromResponse {
        isNextItemFromResponse = false
    } else {
        // ユーザー入力として処理
    }
```

### OpenAI STT 日本語文字化け (2026-01-20)
**問題**: ストリーミング中の部分テキストで日本語が文字化け
**解決**: Unicode正規化とサニタイズ関数を追加
```swift
private func sanitizeUnicodeString(_ input: String) -> String {
    var result = input.precomposedStringWithCanonicalMapping
    result = result.unicodeScalars.filter { $0 != Unicode.Scalar(0xFFFD) }...
}
```

### ⌘Q でアプリが終了する (2026-01-20)
**問題**: メニューバーアプリなのにパネル表示中に⌘Qでアプリが終了
**解決**: `applicationShouldTerminate` でパネル表示中は `.terminateCancel` を返してパネルを閉じるだけにする

### Gemini STT マイク入力 (2026-01-16)
**問題**: Gemini Live APIが期待する16kHzサンプルレートとマイクの48kHzが不一致
**解決**: AudioResamplerを追加してリアルタイムリサンプリング

## 設計パターン・規約

### パネルの排他制御
STTパネルとTTSパネルは同時に開けない。一方を開くと他方は自動的に閉じる。

### ホットキー
- グローバルホットキー: HotKeyService (HotKeyライブラリ使用)
  - "Toggle STT Panel" - STTパネルの開閉（Auto-start recordingがオンなら録音も開始）
  - "Toggle TTS Panel" - TTSパネルの開閉（Auto-speakがオンなら選択テキストを読み上げ）
  - "OCR Region to TTS" - OCR領域選択
  - "Toggle Subtitle Mode" - 字幕モード切替
- パネル内ショートカット: ShortcutSettingsManager

### APIキー管理
- Keychain保存: KeychainService
- 環境変数フォールバック: OPENAI_API_KEY, GEMINI_API_KEY, ELEVENLABS_API_KEY, GROK_API_KEY

### 音声フォーマット
- 入力: 48kHz → 16kHz (リサンプリング)
- 出力: 24kHz PCM → WAV/AAC変換 (AudioConverter)

## ビルド・デプロイ

```bash
# プロジェクト生成
xcodegen generate

# ビルド
xcodebuild -scheme SpeechDock -configuration Debug build

# リリース
rake release:full  # DMG作成 + 公証
```

## ファイル構成

```
speechdock/
├── App/
│   ├── SpeechDockApp.swift  # エントリーポイント
│   ├── AppDelegate.swift     # ライフサイクル管理
│   ├── AppState.swift        # 状態管理
│   └── WindowManager.swift   # About/Settings ウィンドウ
├── Services/
│   ├── RealtimeSTT/          # STTプロバイダ実装
│   ├── TTS/                  # TTSプロバイダ実装
│   ├── Translation/          # 翻訳プロバイダ実装
│   ├── HotKeyService.swift   # グローバルホットキー
│   └── ...
├── Views/
│   ├── FloatingWindow/       # STT/TTSパネル
│   ├── Subtitle/             # 字幕オーバーレイ
│   ├── Settings/             # 設定画面
│   ├── Components/           # 共有UIコンポーネント（翻訳コントロールなど）
│   └── MenuBarView.swift     # メニューバー
├── Resources/
│   ├── Info.plist
│   └── SpeechDock.entitlements
└── project.yml               # XcodeGen設定
```

## UI実装詳細

### パネルレイアウト (2026-01-20 更新)

**STTパネル (`TranscriptionFloatingView.swift`)**
- ヘッダー: Input/Targetセレクタ（フォント: `.callout`）
- Targetセレクタ: アイコンのみ表示（アプリ名は省略、truncation防止）
- Inputセレクタ: アイコンサイズ 16x16（Targetと統一）
- 下部アクションボタン: 字幕トグル、Record/Stop、Paste
- 字幕ボタン: `captions.bubble` / `captions.bubble.fill` アイコン

**TTSパネル (`TTSFloatingView.swift`)**
- ヘッダー: Voice/Modelセレクタ（フォント: `.callout`）
- Voice表示: ハイフン以降を省略して短縮表示
  ```swift
  if let hyphenRange = voice.name.range(of: " - ") {
      return String(voice.name[..<hyphenRange.lowerBound])
  }
  ```
- 下部アクションボタン: OCRボタン、Speak/Stop、Save
- OCRボタン: `text.viewfinder` アイコン、ショートカット表示 "⌃⌥⇧O"

**字幕オーバーレイ (`SubtitleOverlayView.swift`)**
- Recording表示: 13pt、赤ドット付き、停止ショートカット表示（例: "Recording (⌃⌥S to stop)"）
- インラインコントロール: フォントサイズ調整、最大行数調整
- ドラッグ可能（カスタム位置保存）
- クリックスルー（`ignoresMouseEvents = true`）
- 現セッションのみ表示: `currentSessionTranscription`を使用（録音開始時にリセット）

### パネルプレースホルダー (2026-01-21)
テキストエリアが空の時に表示されるガイダンス:

**TTSパネル**:
```
Type text here, or:
• Select text elsewhere and press [ショートカット]
• Use OCR ([ショートカット]) to capture screen text
```

**STTパネル**（録音中でない場合）:
```
Press Record ([ショートカット]) to start transcription
```

※ショートカットはユーザーの現在の設定から動的に取得

### フォントサイズ規約
- パネルヘッダーのラベル: `.callout` (約14pt)
- 小さいラベル: `.caption` (約12pt)
- アイコンサイズ: セレクタ内は 16x16、ボタン内は `.body`

### コンパクトボタンスタイリング規約 (2026-01-22)
パネル下部の Subtitle、Target、Paste ボタンと翻訳コントロール（Translate/Original）は統一されたスタイリングを使用。

**コンパクトボタン共通スタイル**:
```swift
HStack(spacing: 4) {
    Image(systemName: "icon.name")
        .font(.system(size: 10))  // アイコン: 10pt
    Text("Label")
        .font(.system(size: 11, weight: .medium))  // ラベル: 11pt medium
    Text("(⌘X)")
        .font(.system(size: 10))  // ショートカット: 10pt
        .foregroundColor(.secondary)
}
.fixedSize()  // テキスト折り返し防止
.padding(5)   // 4方向均等パディング
.background(Color.secondary.opacity(0.1))
.cornerRadius(4)
// .buttonStyle(.plain) を使用
```

**翻訳コントロール (Translate/Original)**:
```swift
// 内部ボタン
.padding(.horizontal, 6)
.padding(.vertical, 3)
.background(...)
.cornerRadius(4)

// コンテナ
.padding(.horizontal, 4)
.frame(height: 28)  // 固定高さ
```

**フローティングコントロール（フォントサイズ、スペルチェック等）**:
```swift
.padding(.horizontal, 8)
.frame(height: 28)  // 固定高さ（翻訳コントロールと同じ）
```

### 翻訳機能 (2026-01-22)
テキストエリアの左下にフローティング翻訳コントロールを配置。

**コントロール構成**:
- `[🌐 日本語 ▼]` - 言語セレクター（選択すると翻訳実行）
- `[🌐 Original ◀]` - 翻訳表示中に表示（オリジナルに戻す）
- `[⚡]` - プロバイダ切り替え（macOS/OpenAI/Gemini）

**対応プロバイダ**:
- **macOS**: オンデバイス翻訳（macOS 26+、APIキー不要、~18言語）
- **OpenAI**: GPT-4o-mini（APIキー必要、100+言語）
- **Gemini**: Gemini 2.0 Flash（APIキー必要、100+言語）

**状態フロー**:
```
idle → translating → translated → idle (Original押下)
```

**TTS言語連動**:
- 翻訳完了時: `selectedTTSLanguage` を翻訳先言語に自動変更
- オリジナルに戻す時: 保存しておいたTTS言語を復元

**表示条件**:
- テキストが3文字以上ある場合のみ表示
- 録音中/文字起こし中/TTS再生中は非表示

**プロバイダ自動同期** (2026-01-22):
パネル切り替え時に翻訳プロバイダをSTT/TTSプロバイダに合わせて自動同期:
| STT/TTSプロバイダ | 翻訳プロバイダ |
|------------------|---------------|
| OpenAI | OpenAI |
| Gemini | Gemini |
| Grok | Grok |
| ElevenLabs/macOS | macOS |

実装: `syncTranslationProviderForSTT()`, `syncTranslationProviderForTTS()` (AppState.swift)

## WebSocket実装パターン

### 共通構造
```swift
class XXXRealtimeSTT: RealtimeSTTService {
    private var webSocketTask: URLSessionWebSocketTask?
    private var accumulatedText = ""
    private var currentPartialText = ""

    func startRecording() async throws {
        // 1. WebSocket接続
        // 2. 初期設定送信
        // 3. 音声データ送信ループ開始
        // 4. メッセージ受信ループ開始
    }

    func stopRecording() async {
        // 1. 音声送信停止
        // 2. WebSocket切断
        // 3. 最終テキスト確定
    }
}
```

### Grok Realtime API イベントフロー
```
→ session.update (設定)
→ input_audio_buffer.append (音声データ)
← conversation.item.added (ユーザー入力確定)
← response.output_item.added (レスポンス開始マーカー)
← conversation.item.added (レスポンスアイテム - スキップ)
← response.audio_transcript.delta (部分テキスト)
← response.audio_transcript.done (テキスト確定)
```

### OpenAI Realtime API イベントフロー
```
→ session.update (設定)
→ input_audio_buffer.append (音声データ)
← conversation.item.input_audio_transcription.delta (部分テキスト)
← conversation.item.input_audio_transcription.completed (確定)
```

### Gemini Live API イベントフロー
```
→ BidiGenerateContentSetup (初期設定)
→ BidiGenerateContentRealtimeInput (音声データ)
← BidiGenerateContentServerContent (テキスト結果)
```

## デバッグ手法

### ログ出力パターン
```swift
#if DEBUG
print("ClassName: message - \(variable)")
#endif
```

### WebSocketデバッグ
```swift
#if DEBUG
print("WS received: \(String(data: data, encoding: .utf8) ?? "nil")")
#endif
```

### 条件付きコンパイル
```swift
#if compiler(>=6.1)
// macOS 26+ (SpeechAnalyzer)
#endif

@available(macOS 26, *)
// macOS 26+専用API
```

## 今後の検討事項・課題

### TTS速度制御の設計決定 (2026-01-21)
**リアルタイム再生**: ローカル速度制御（AVAudioUnitTimePitch）
- APIには常に速度1.0xで音声生成を依頼
- すべての速度制御はローカルのAVAudioUnitTimePitchで実行
- 再生中の動的な速度変更が可能

**Save Audio（バッチ処理）**: API速度パラメータを使用（速度 != 1.0の場合のみ）
| プロバイダ | パラメータ | 範囲 | 備考 |
|-----------|----------|------|------|
| OpenAI | `speed` | 0.25-4.0 | tts-1/tts-1-hdのみ（gpt-4o-mini-ttsは非対応） |
| ElevenLabs | `voice_settings.speed` | 0.7-1.2 | アプリの0.5-2.0から変換 |
| Gemini | テキスト先頭にペース指示 | 自然言語 | "Speak slowly..."など |
| macOS | `-r` (wpm) | 50-500 | 基準175wpm × 速度倍率 |
| Grok | - | - | 速度パラメータ非対応 |

**トレードオフ**:
- ✅ 利便性: 再生中にリアルタイムで速度調整可能
- ⚠️ 音質: 一部のプロバイダはAPI側で速度を指定すると「ゆっくりした話し方」など発話スタイル自体を調整する可能性がある

### Text Replacement機能 (2026-01-21)
**ビルトインパターン**（正規表現ベース）:
- URLs: `https?://...` → " URL "
- Email: `user@domain.com` → " Email "
- File Paths: `/path/to/file` → " Path "

**特徴**:
- 各パターンはトグルでオン/オフ可能
- 置き換え文字列はユーザーがカスタマイズ可能
- Export/Importでカスタムルールとビルトインパターン設定の両方を保存
- TTSパネルのテキストエリアで置き換え対象にオレンジ色の下線+ツールチップ表示

### 未実装・部分実装
- [ ] ElevenLabs音声キャッシュの有効期限管理

### 音声ファイル文字起こし機能 (2026-01-22)
STTパネルへの音声ファイルのドラッグ＆ドロップ、またはメニューバーからの選択による文字起こし機能。

**対応プロバイダー（動的表示）**:
| プロバイダー | 対応フォーマット | 最大サイズ | 最大長 | 使用API |
|-------------|-----------------|-----------|--------|---------|
| OpenAI | MP3, WAV, M4A, FLAC, WebM, MP4 | 25MB | 無制限 | Whisper API |
| Gemini | MP3, WAV, AAC, OGG, FLAC | 20MB | ~10分 | generateContent API |
| ElevenLabs | MP3, WAV, M4A, OGG, FLAC | 25MB | ~2時間 | Scribe v2 API |
| Grok | - | - | - | リアルタイムのみ |
| macOS | - | - | - | リアルタイムのみ |

**動的UI表示**:
- STTパネルのプレースホルダー: 選択中のプロバイダの対応フォーマット・制限を表示
- メニューバー: プロバイダごとの説明を表示（例: "Whisper API (max 25MB)"）
- 非対応プロバイダ選択時: 切り替えを促すメッセージを表示

**使用方法**:
1. ドラッグ＆ドロップ: STTパネルのテキストエリアに音声ファイルをドロップ
2. メニューバー: 「Transcribe Audio File...」を選択してファイルを選択

**状態管理**:
- `TranscriptionState.transcribingFile` - ファイル文字起こし中の状態
- ファイル文字起こし中は録音不可（排他制御）
- キャンセル可能（Escキーまたはキャンセルボタン）
- 通知ダイアログ: エラーではなく情報として表示（`.informational`スタイル）

**プロバイダ固有プロパティ** (`RealtimeSTTProvider`):
- `supportsFileTranscription: Bool` - ファイル文字起こし対応
- `supportedAudioFormats: String` - 対応フォーマット一覧
- `maxFileSizeMB: Int` - 最大ファイルサイズ
- `maxAudioDuration: String` - 最大音声長
- `fileTranscriptionDescription: String` - UI表示用の短い説明

**実装ファイル**:
- `Services/FileTranscriptionService.swift` - ファイル文字起こしサービス
- `Services/RealtimeSTT/RealtimeSTTProtocol.swift` - プロバイダ固有プロパティ
- `App/AppState.swift` - `transcribeAudioFile()`, `cancelFileTranscription()`, `openAudioFileForTranscription()`
- `Views/FloatingWindow/TranscriptionFloatingView.swift` - ドラッグ＆ドロップUI
- `Views/MenuBarView.swift` - メニュー項目

### 改善候補
- パネル位置の記憶と復元
- 複数言語同時認識

### 既知の制限
- STTパネルとTTSパネルは排他（同時表示不可）
- System Audio / App AudioはScreen Recording権限必須

## コミット規約

```
<type>: <subject>

Types:
- Add: 新機能追加
- Fix: バグ修正
- Update: 機能改善・更新
- Refactor: リファクタリング
- Remove: 機能削除
```

## 注意事項

- バンドルID: `com.speechdock.app`
- Keychainサービス名: `com.speechdock.apikeys` (旧: com.typetalk.apikeys)
- 旧TypeTalk.xcodeprojは削除済み、SpeechDock.xcodeprojを使用

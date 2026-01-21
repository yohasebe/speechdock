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
│   ├── HotKeyService.swift   # グローバルホットキー
│   └── ...
├── Views/
│   ├── FloatingWindow/       # STT/TTSパネル
│   ├── Subtitle/             # 字幕オーバーレイ
│   ├── Settings/             # 設定画面
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
- Recording表示: 13pt、赤ドット付き
- インラインコントロール: フォントサイズ調整、最大行数調整
- ドラッグ可能（カスタム位置保存）
- クリックスルー（`ignoresMouseEvents = true`）

### フォントサイズ規約
- パネルヘッダーのラベル: `.callout` (約14pt)
- 小さいラベル: `.caption` (約12pt)
- アイコンサイズ: セレクタ内は 16x16、ボタン内は `.body`

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

### 未実装・部分実装
- [ ] GrokTTS.swift - 新規追加されたが詳細未確認
- [ ] ElevenLabs音声キャッシュの有効期限管理

### 改善候補
- パネル位置の記憶と復元
- 複数言語同時認識
- 音声ファイルからの文字起こし（バッチ処理）

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

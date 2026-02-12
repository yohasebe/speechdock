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

### 翻訳 (`Services/Translation/`)
デフォルトはmacOSオンデバイス翻訳（`MacOSTranslation.swift`、APIキー不要、macOS 26+）。
追加のAPIキーがあれば外部LLMプロバイダも利用可能（詳細は後述の「翻訳の発展設定」を参照）。

### ウィンドウ管理
- `FloatingWindowManager.swift` - STT/TTSパネル管理（排他制御）
- `SubtitleOverlayManager.swift` - 字幕オーバーレイ（クリックスルー）
- `FloatingMicButtonManager.swift` - クイック入力ボタン（常時表示、ドラッグ可能）
- `FloatingMicTextHUD.swift` - クイック入力HUD（リアルタイム文字起こし表示）
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

### STTパネル録音再開時のテキスト重複 (2026-01-26)
**問題**: STTパネルで録音を停止して再開すると、前のテキストが重複表示される
**原因**: `TranscriptionFloatingView`の`.onChange(of: isRecording)`で録音開始時に`currentTranscription = editedText`をセットしていた。これが`.onChange(of: currentTranscription)`をトリガーし、`baseText`（前回停止時の値）と`newValue`（古いテキスト）でアペンド処理が走り、`editedText = baseText + " " + newValue`で重複
**解決**: 録音開始時の`currentTranscription = editedText`同期を削除。字幕は`currentSessionTranscription`を使用しているため、この同期は不要だった
```swift
// 修正前（バグあり）
if newValue {
    appState.currentTranscription = editedText  // これが重複の原因
    baseText = editedText.trimmingCharacters(in: .whitespaces)
}

// 修正後
if newValue {
    // currentTranscriptionへの同期を削除 - 字幕はcurrentSessionTranscriptionを使用
    baseText = editedText.trimmingCharacters(in: .whitespaces)
}
```

### テキスト選択のCGEvent実装 (2026-01-22)
**問題**: AppleScriptでのCmd+Cシミュレーションが権限問題で失敗（特にLINE等の一部アプリ）
**解決**: CGEventを使用した低レベル実装に変更

```swift
/// Simulate Cmd+C using CGEvent (no System Events permission required)
private func copySelectionWithCGEvent() {
    let keyCodeC: CGKeyCode = 8
    let source = CGEventSource(stateID: .hidSystemState)

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: false) else { return }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand

    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}
```

**利点**:
- System Eventsの自動化権限が不要
- `.hidSystemState`でハードウェア入力としてシミュレート
- より多くのアプリで動作

### TTSホットキーでのテキストキャプチャ (2026-01-22)
**問題**: TTSパネルが開いている状態でホットキーを押すと、他アプリからテキストがキャプチャできない

**解決策**:
1. ホットキーハンドラ内で即座にCmd+Cを送信（非同期スケジューリング前）
2. ターゲットアプリを`activate()`で明示的にアクティブ化
3. クリップボードの変更を監視してテキストを取得
4. 取得したテキストをMainActorタスクに渡す

```swift
nonisolated func ttsHotKeyPressed() {
    let frontmostApp = NSWorkspace.shared.frontmostApplication
    let savedClipboardState = ClipboardService.shared.saveClipboardState()

    if let targetApp = frontmostApp {
        targetApp.activate()
        Thread.sleep(forTimeInterval: 0.05)  // アクティベーション待機
        sendCopyCommand()
        Thread.sleep(forTimeInterval: 0.15)  // クリップボード待機
        copiedText = NSPasteboard.general.string(forType: .string)
        ClipboardService.shared.restoreClipboardState(savedClipboardState)  // 復元
    }

    Task { @MainActor in
        self.toggleTTS(frontmostApp: frontmostApp, precopiedText: copiedText)
    }
}
```

### forceTextUpdate機構 (2026-01-22)
**問題**: ScrollableTextViewがフォーカスを持っている間、外部からのテキスト更新がブロックされる

**解決**: `forceTextUpdate`フラグを追加して強制更新を可能に

```swift
// ScrollableTextView
var forceTextUpdate: Bool = false

func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let isFirstResponder = textView.window?.firstResponder === textView
    let textChanged = textView.string != text
    // forceTextUpdate時はフォーカスに関係なく更新
    let shouldUpdate = textChanged && (!isFirstResponder || text.isEmpty || !isEditable || forceTextUpdate)

    if shouldUpdate {
        textView.string = text
    }
}

// 使用側（TTSFloatingView, TranscriptionFloatingView）
.onChange(of: appState.ttsText) { _, newValue in
    forceTextUpdate = true
    editableText = newValue
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        forceTextUpdate = false
    }
}
```

**適用箇所**:
- TTSパネル: ホットキーでのテキストキャプチャ、翻訳結果表示
- STTパネル: リアルタイム文字起こし、ファイル文字起こし結果、翻訳結果表示

### ElevenLabs TTS language_code問題 (2026-01-22)
**問題**: `Model 'eleven_v3' does not support the language_code eng` エラー
**解決**: v2/multilingualモデルのみに`language_code`パラメータを送信

```swift
let supportsLanguageCode = modelId.contains("v2") || modelId.contains("multilingual")
if supportsLanguageCode, let langCode = langCode.toElevenLabsTTSCode() {
    body["language_code"] = elevenLabsCode
}
```

### AppleScript起動時の初期化待機 (2026-01-26)
**問題**: AppleScriptでアプリを起動した場合、コマンドがアプリ初期化完了前に実行され、機能しないことがある
**原因**: `AppDelegate.applicationDidFinishLaunching`内のセットアップが`Task { @MainActor in }`で非同期実行されるため、AppleScriptコマンドが先に走る可能性
**解決**:
1. `AppState.isInitialized`フラグを追加
2. `AppDelegate`でセットアップ完了後にフラグをtrueに設定
3. AppleScriptコマンドで`waitForInitialization()`を呼び出して最大5秒待機

```swift
// AppleScriptErrors.swift
@MainActor
func waitForInitialization(timeout: TimeInterval = 5.0) async -> Bool {
    let startTime = Date()
    while !AppState.shared.isInitialized {
        if Date().timeIntervalSince(startTime) > timeout {
            return false
        }
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    }
    return true
}

// 使用例（SpeechDockCommands.swift）
Task { @MainActor in
    let initialized = await self.waitForInitialization(timeout: 5.0)
    guard initialized else {
        self.setAppleScriptError(.appNotInitialized,
            message: "SpeechDock is still initializing. Please try again in a moment.")
        self.resumeExecution(withResult: nil)
        return
    }
    // コマンド実行...
}
```

### WebSocket接続検証パターン (2026-01-26)
**問題**: WebSocket接続後に単純なsleepで待機していたため、接続失敗時にサイレントに失敗
**解決**: `session.created`イベントをタイムアウト付きで待機し、接続失敗時にエラーを報告

```swift
// 接続状態フラグ
private var sessionCreated = false

// 接続時にフラグをリセットして待機
task.resume()
sessionCreated = false
startReceivingMessages()
try await waitForSessionCreated(timeout: 5.0)

// session.createdイベント受信時にフラグを設定
case "session.created":
    sessionCreated = true

// 待機関数
private func waitForSessionCreated(timeout: TimeInterval) async throws {
    let startTime = Date()
    while !sessionCreated {
        if webSocketTask?.state == .completed || webSocketTask?.state == .canceling {
            throw RealtimeSTTError.connectionError("WebSocket connection closed unexpectedly")
        }
        if Date().timeIntervalSince(startTime) > timeout {
            throw RealtimeSTTError.connectionError("Connection timeout: server did not respond")
        }
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    }
}
```

**適用ファイル**: `OpenAIRealtimeSTT.swift`, `GrokRealtimeSTT.swift`, `ElevenLabsRealtimeSTT.swift`

### 字幕リアルタイム翻訳のモデル不一致 (2026-01-27)
**問題**: 字幕翻訳で別プロバイダのモデルIDが使用され、APIエラーが発生
**原因**: `appState.selectedTranslationModel`はパネル翻訳と共有されており、異なるプロバイダのモデルが設定されている可能性があった
**解決**: 字幕翻訳では`provider.defaultModelId`を使用するよう変更
```swift
// SubtitleTranslationService.swift
private func ensureTranslator(for appState: AppState) async {
    let provider = appState.subtitleTranslationProvider
    // Use provider's default model for subtitle translation
    let modelToUse = provider.defaultModelId
    translator = ContextualTranslatorFactory.makeTranslator(for: provider, model: modelToUse)
}
```

### 字幕パネルの言語重複表示 (2026-01-27)
**問題**: 字幕オーバーレイで翻訳言語が2箇所に表示されていた（録音インジケータと翻訳トグル）
**解決**: 録音インジケータから言語表示を削除し、翻訳トグル側にのみ表示

## 設計パターン・規約

### 字幕翻訳設定の同期 (2026-01-27)
字幕モード開始時にSTTパネルの翻訳設定を字幕設定に同期：

```swift
// AppState.swift
var subtitleModeEnabled: Bool = false {
    didSet {
        guard !isLoadingPreferences else { return }
        if subtitleModeEnabled && !oldValue {
            syncSubtitleTranslationSettingsFromPanel()
        }
        updateSubtitleOverlay()
        savePreferences()
    }
}

private func syncSubtitleTranslationSettingsFromPanel() {
    if subtitleTranslationProvider != translationProvider {
        subtitleTranslationProvider = translationProvider
    }
    if subtitleTranslationLanguage != translationTargetLanguage {
        subtitleTranslationLanguage = translationTargetLanguage
    }
    // Note: Subtitle mode uses provider.defaultModelId (not selectedTranslationModel)
}
```

### サービス作成前のクリーンアップ (2026-01-26)
STT/TTS/翻訳サービスを新規作成する前に、既存のサービスを明示的に停止・nilする防御的パターン：

```swift
// 新しいサービス作成前に既存をクリーンアップ（防御的措置）
realtimeSTTService?.stopListening()
realtimeSTTService = nil

// 新しいサービスを作成
realtimeSTTService = RealtimeSTTFactory.makeService(for: selectedRealtimeProvider)
```

**適用箇所**:
- `startRealtimeSTT()` - STTサービス
- `startRealtimeSTTForQuickMode()` - クイック入力STTサービス
- `translateText()` - 翻訳サービス

### パネルの排他制御
STTパネルとTTSパネルは同時に開けない。一方を開くと他方は自動的に閉じる。

### ホットキー
- グローバルホットキー: HotKeyService (HotKeyライブラリ使用)
  - "Toggle STT Panel" - STTパネルの開閉（Auto-start recordingがオンなら録音も開始）
  - "Toggle TTS Panel" - TTSパネルの開閉（Auto-speakがオンなら選択テキストを読み上げ）
  - "OCR Region to TTS" - OCR領域選択
  - "Toggle Subtitle Mode" - 字幕モード切替
  - "Quick Transcription" (⌃⌥M) - クイック入力の開始/停止
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
│   │   ├── ContextualTranslator.swift    # 字幕用コンテキスト対応翻訳
│   │   ├── SubtitleTranslationService.swift  # 字幕リアルタイム翻訳
│   │   └── ...
│   ├── HotKeyService.swift   # グローバルホットキー
│   └── ...
├── Views/
│   ├── FloatingWindow/       # STT/TTSパネル
│   ├── FloatingMicButton/    # クイック入力ボタン
│   ├── Subtitle/             # 字幕オーバーレイ
│   ├── Settings/             # 設定画面
│   ├── Components/           # 共有UIコンポーネント（翻訳コントロールなど）
│   └── MenuBarView.swift     # メニューバー
├── Tests/                    # ユニットテスト
│   ├── SubtitleTranslationServiceTests.swift
│   ├── TranslationServiceTests.swift
│   └── ...
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

### 翻訳機能 (2026-01-27 更新)
テキストエリアの左下にフローティング翻訳コントロールを配置。
デフォルトはmacOSオンデバイス翻訳（APIキー不要、~18言語対応）。

**UI構成**（言語選択と翻訳実行を分離）:
```
[🌐 Translate] [→ Japanese ▼] [OpenAI ▼] [GPT-5 Nano ▼]
```
- `[🌐 Translate]` - 翻訳実行ボタン（テキスト3文字以上で有効）
- `[→ Japanese ▼]` - 言語セレクタ（選択のみ、翻訳は実行しない）
- `[OpenAI ▼]` - プロバイダセレクタ
- `[GPT-5 Nano ▼]` - モデルセレクタ（macOS以外のプロバイダで表示）
- 翻訳表示中: `[🌐 Original ◀]` ボタンが表示（オリジナルに戻す）

**設計理由**:
- 字幕モード用に翻訳先言語だけを変更したい場合、誤って翻訳が実行されるのを防止
- 同じ言語への再翻訳が「Translate」ボタン押下で可能

**状態フロー**:
```
idle → translating → translated → idle (Original押下)
```

**TTS言語連動**:
- 翻訳完了時: `selectedTTSLanguage` を翻訳先言語に自動変更
- オリジナルに戻す時: 保存しておいたTTS言語を復元

**表示条件**:
- テキストが3文字以上ある場合のみ「Translate」ボタンが有効
- 録音中/文字起こし中/TTS再生中は非表示

#### 翻訳の発展設定

APIキーを設定すると外部LLMプロバイダが利用可能になり、100+言語への翻訳やより高品質な翻訳が可能。

**プロバイダとモデル** (Settings > General > Translation で変更):
| プロバイダ | モデル | 備考 |
|-----------|--------|------|
| macOS (デフォルト) | System | オンデバイス、APIキー不要、macOS 26+必須 |
| OpenAI | GPT-5 Nano (default), GPT-5 Mini, GPT-5.2 | APIキー必要 |
| Gemini | Gemini 3 Flash (default), Gemini 3 Pro | APIキー必要 |
| Grok | Grok 3 Fast (default), Grok 3 Mini Fast | APIキー必要 |

**macOSプロバイダのOS要件**:
- macOS 26+でのみ表示（`#if compiler(>=6.1)` と `@available(macOS 26.0, *)` で制御）
- macOS 25以下ではプロバイダリストに表示されない

**GPT-5系の技術的制約**:
- `temperature`パラメータ非対応（推論モデルのため）
- `reasoning_effort`で推論量を制御: `gpt-5-nano/mini` → `"minimal"`, `gpt-5.2` → `"none"`
- これにより翻訳タスクでのレスポンスを高速化

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
| macOS (26+) | MP3, WAV, M4A, AAC, AIFF, FLAC, MP4 | 500MB | 無制限 | SpeechAnalyzer |
| macOS (<26) | - | - | - | リアルタイムのみ |

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

### クイック入力機能（Floating Mic Button） (2026-01-25)
STTパネルを開かずに音声入力を行う機能。フローティングマイクボタンとテキストHUDで構成。

**コンポーネント**:
- `FloatingMicButtonManager.swift` - ボタンウィンドウ管理
- `FloatingMicButtonView.swift` - ボタンUI（SwiftUI）
- `FloatingMicTextHUD.swift` - テキスト表示HUD

**動作フロー**:
1. メニューバーから「Floating Mic Button」をオンにしてボタンを表示
2. ボタンをクリック、または⌃⌥Mで録音開始
3. HUDにリアルタイムで文字起こしテキスト表示
4. 再度クリック、または⌃⌥Mで録音停止
5. 文字起こしテキストをクリップボード経由で最前面アプリにペースト

**UI仕様**:
- **ボタン**: 48pxの丸型、ドラッグで移動可能、位置は永続化
- **HUD**: 320x120px、半透明黒背景（opacity 0.75）、ドラッグで移動可能、ボタン移動時に追従
- **録音中表示**: ボタンが赤く変化、パルスアニメーション、HUDに「Recording (⌃⌥M to stop)」表示
- **ツールチップ**: 「Click or ⌃⌥M to start dictation」

**技術詳細**:
- `NonActivatingWindow` (canBecomeKey/canBecomeMain = false) でフォーカス奪取を防止
- `NSWorkspace.didActivateApplicationNotification` で最前面アプリを追跡
- ドラッグは `NSEvent.mouseLocation` で直接追跡（SwiftUIのDragGestureの座標系問題を回避）
- HUDは `ScrollViewReader` + 自動スクロールでテキスト更新時に最下部へ

**AppleScript対応**:
```applescript
-- プロパティ
tell application "SpeechDock"
    quick transcription visible -- ボタン表示状態 (r/w)
end tell

-- コマンド
tell application "SpeechDock"
    start quick transcription  -- 録音開始
    stop quick transcription   -- 録音停止（テキストを返す）
    toggle quick transcription -- 開始/停止トグル
end tell
```

**実装ファイル**:
- `Views/FloatingMicButton/FloatingMicButtonManager.swift`
- `Views/FloatingMicButton/FloatingMicButtonView.swift`
- `Views/FloatingMicButton/FloatingMicTextHUD.swift`
- `Services/AppleScript/SpeechDockCommands.swift` - AppleScriptコマンド
- `Services/AppleScript/AppleScriptBridge.swift` - AppleScriptプロパティ
- `Resources/SpeechDock.sdef` - AppleScript辞書定義

### 字幕リアルタイム翻訳機能 (2026-01-27)
字幕モードでのリアルタイム翻訳機能。すべての音声ソース（マイク、システム音声、アプリ音声）で利用可能。

**コンポーネント**:
- `Services/Translation/SubtitleTranslationService.swift` - リアルタイム翻訳サービス（シングルトン）
- `Services/Translation/ContextualTranslator.swift` - コンテキスト対応翻訳プロトコル・実装
- `Views/Subtitle/SubtitleOverlayView.swift` - 字幕オーバーレイUI

**動作フロー**:
1. STTから累積テキストを受信
2. デバウンス処理（プロバイダごとに異なる間隔）
3. 翻訳実行（キャッシュヒット時は即座に返却）
4. 字幕に翻訳結果を表示

**設計ポイント**:
- **累積テキスト対応**: STTは累積テキストを送信するため、全文翻訳アプローチを採用
- **デバウンス**: プロバイダごとに最適化された間隔（macOS: 300ms, Gemini: 600ms, OpenAI/Grok: 800ms）
- **ポーズ検出**: 1.5秒の無音で自動的に翻訳をトリガー
- **キャッシュ**: LRUキャッシュ（最大200エントリ）で同じテキストの再翻訳を回避
- **コンテキスト**: 直近2文を翻訳コンテキストとして使用（LLMプロバイダのみ）

**状態管理** (`AppState`):
```swift
var subtitleTranslationEnabled: Bool      // 翻訳有効/無効
var subtitleTranslationLanguage: LanguageCode  // 翻訳先言語
var subtitleTranslationProvider: TranslationProvider  // 翻訳プロバイダ
var subtitleTranslationState: SubtitleTranslationState  // idle/translating/error
var subtitleTranslatedText: String        // 翻訳結果テキスト
var subtitleShowOriginal: Bool            // 原文も表示するか
```

**設定の同期**:
- 字幕モード開始時にSTTパネルの翻訳設定（プロバイダ、言語）を自動同期
- 字幕オーバーレイ上でプロバイダ・言語を個別に変更可能
- 設定はUserDefaultsに永続化

**プロバイダごとのモデル**:
字幕翻訳は各プロバイダのデフォルトモデルを使用（`provider.defaultModelId`）。
これにより、パネル翻訳で異なるプロバイダのモデルを選択していても競合しない。

**UI仕様**:
- 翻訳トグル: 🌐アイコン（青=有効、白=無効）
- プロバイダセレクタ: 翻訳有効時のみ表示
- 言語セレクタ: 翻訳有効時のみ表示（macOSプロバイダはインストール済み言語のみ）
- 翻訳中インジケータ: 「Recording」の横にProgressView表示

**エラー処理**:
- 翻訳エラー時は3秒後に自動リセット
- プロバイダ/言語変更時にエラー状態をリセット
- 空の翻訳結果はキャッシュしない

**クリーンアップ**:
- 字幕モード終了時に`SubtitleTranslationService.shared.reset()`を呼び出し
- debounceTask、pauseCheckTaskを明示的にキャンセル

**プロバイダ可用性**:
- macOSプロバイダはmacOS 26+でのみ選択可能（Translation framework依存）
- APIキーのないLLMプロバイダは選択肢から除外

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

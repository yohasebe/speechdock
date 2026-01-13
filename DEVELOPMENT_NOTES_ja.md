# 開発ノート

このドキュメントは TypeTalk 開発における実装の詳細、設計上の決定、動作仕様をまとめたものです。

[English](DEVELOPMENT_NOTES.md) | 日本語

## 目次

- [ソースからのビルド](#ソースからのビルド)
- [ウィンドウレベルの階層](#ウィンドウレベルの階層)
- [設定の永続化](#設定の永続化)
- [音声入力ソース](#音声入力ソース)
- [STT/TTS 処理ライフサイクル](#stttts-処理ライフサイクル)
- [パネルショートカット](#パネルショートカット)
- [API キー管理](#api-キー管理)
- [スレッドセーフティ](#スレッドセーフティ)
- [キャッシュ管理](#キャッシュ管理)
- [権限](#権限)
- [UI/UX ガイドライン](#uiux-ガイドライン)
- [ビルドとリリース](#ビルドとリリース)
- [既知の問題と回避策](#既知の問題と回避策)

---

## ソースからのビルド

### 前提条件

- Xcode 16.0 以降
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (オプション、プロジェクト生成用)
- Apple Developer アカウント (コード署名と公証用)

### ビルド手順

1. リポジトリをクローン:
   ```bash
   git clone https://github.com/yohasebe/TypeTalk.git
   cd TypeTalk
   ```

2. Xcode プロジェクトを生成 (XcodeGen 使用時):
   ```bash
   xcodegen generate
   ```

3. Xcode で開く:
   ```bash
   open TypeTalk.xcodeproj
   ```

4. ビルドして実行 (Cmd + R)

### ビルドスクリプト

```bash
# リリース版をビルド
./scripts/build.sh

# DMG インストーラーを作成
./scripts/create-dmg.sh

# 配布用に公証 (Apple Developer アカウントが必要)
./scripts/notarize.sh
```

### 環境変数 (開発専用)

開発時は、設定 UI の代わりに環境変数で API キーを設定できます:

```bash
export OPENAI_API_KEY="your-openai-key"
export GEMINI_API_KEY="your-gemini-key"
export ELEVENLABS_API_KEY="your-elevenlabs-key"
```

注意: 環境変数は開発専用です。本番ユーザーは設定 UI から API キーを設定してください (macOS キーチェーンに安全に保存されます)。

---

## ウィンドウレベルの階層

TypeTalk で使用する macOS ウィンドウレベル (低い順):

| レベル | 値 | 用途 |
|-------|-----|------|
| `.normal` | 0 | 標準ウィンドウ |
| `.floating` | 3 | 設定ウィンドウ |
| `.popUpMenu` | 101 | メニューバーポップオーバー |
| `popUpMenu + 1` | 102 | STT/TTS フローティングパネル |
| `popUpMenu + 2` | 103 | 保存ダイアログ (NSSavePanel) |

### 設計理由

- **メニューバーポップオーバー**は STT/TTS パネルより**下**に表示 (パネル操作時の誤クリック防止)
- **保存ダイアログ**は STT/TTS パネルより**上**に表示 (操作可能にするため)
- **設定ウィンドウ**は標準の `.floating` レベルを使用

### 保存ダイアログの設定

```swift
savePanel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.popUpMenu.rawValue) + 2)
savePanel.contentMinSize = NSSize(width: 400, height: 250)
savePanel.setContentSize(NSSize(width: 500, height: 350))
```

---

## 設定の永続化

### 永続化される設定 (UserDefaults に保存)

| 設定 | キー | 備考 |
|------|-----|------|
| STT プロバイダ | `selectedRealtimeProvider` | |
| STT モデル | `selectedRealtimeSTTModel` | |
| TTS プロバイダ | `selectedTTSProvider` | |
| TTS ボイス | `selectedTTSVoice` | |
| TTS モデル | `selectedTTSModel` | |
| TTS 速度 | `selectedTTSSpeed` | |
| STT 言語 | `selectedSTTLanguage` | |
| TTS 言語 | `selectedTTSLanguage` | |
| 音声入力ソースタイプ | `selectedAudioInputSourceType` | **例外: App Audio は Microphone にリセット** |
| マイクデバイス UID | `selectedAudioInputDeviceUID` | |
| ログイン時に起動 | `launchAtLogin` | |

### セッション限定の設定 (永続化されない)

| 設定 | 理由 |
|------|------|
| `selectedAudioAppBundleID` | App Audio は本質的にセッション固有 |
| `AudioInputSourceType.applicationAudio` | アプリ再起動時に `.microphone` にリセット |

### 実装の詳細

```swift
// loadPreferences() 内
if audioSourceType == .applicationAudio {
    selectedAudioInputSourceType = .microphone  // App Audio を Microphone にリセット
}

// savePreferences() 内
let sourceTypeToSave = selectedAudioInputSourceType == .applicationAudio
    ? .microphone
    : selectedAudioInputSourceType
```

---

## 音声入力ソース

### 利用可能なソース

| ソース | 設定パネル | メニューバー | STT パネル | 備考 |
|--------|-----------|-------------|-----------|------|
| マイク | Yes | Yes | Yes | デフォルトソース |
| システムオーディオ | Yes | Yes | Yes | 画面収録権限が必要 |
| アプリオーディオ | **No** | Yes | Yes | セッション限定、画面収録権限が必要 |

### マイクデバイス選択

- 利用可能: メニューバー、STT パネル
- 利用不可: 設定パネル (一般設定としては細かすぎる)
- 永続化: Yes (`selectedAudioInputDeviceUID`)

### App Audio の動作

- 選択はセッション限定 (アプリ再起動時にリセット)
- 設定パネルには表示されない (メニューバーまたは STT パネルからのみ選択可能)
- キャプチャするには対象アプリケーションが実行中である必要あり
- 音声ソースメニューからアプリリストを更新可能

---

## STT/TTS 処理ライフサイクル

### パネルを閉じた時の動作

STT または TTS パネルが閉じられた時 (どの方法でも):

1. **STT 録音**: `cancelRecording()` で自動キャンセル
2. **TTS 再生**: `stopTTS()` で自動停止
3. **ローディング状態**: 進行中であればキャンセル

`FloatingWindowManager.setupWindowCloseObserver()` での実装:

```swift
NotificationCenter.default.addObserver(
    forName: NSWindow.willCloseNotification,
    object: window,
    queue: .main
) { [weak self] _ in
    if let appState = self?.currentAppState {
        if appState.isRecording {
            appState.cancelRecording()
        }
        if appState.ttsState == .speaking || appState.ttsState == .loading {
            appState.stopTTS()
        }
    }
}
```

### Cmd+Q の動作

- STT/TTS パネルが表示中: パネルのみ閉じる (アプリは終了しない)
- パネルが表示されていない: アプリを通常終了

### アプリケーション終了

- @MainActor 状態への安全な同期アクセスに `MainActor.assumeIsolated` を使用
- 終了前にアクティブな STT/TTS をキャンセル
- 処理がアクティブな場合は `.terminateCancel` を返し、クリーンアップ後に終了

### 文字起こしタイムアウト保護

`isTranscribing` フラグのスタックによる潜在的なデッドロックを防止:

```swift
private let transcriptionTimeout: TimeInterval = 30.0
private var transcriptionStartTime: Date?

// 長時間スタックしている場合は自動リセット
if isTranscribing, let startTime = transcriptionStartTime {
    if Date().timeIntervalSince(startTime) > transcriptionTimeout {
        isTranscribing = false
        transcriptionStartTime = nil
    }
}
```

---

## パネルショートカット

### グローバルショートカット (カスタマイズ可能)

| 操作 | デフォルト | 設定キー |
|------|-----------|----------|
| 録音開始/停止 (STT) | `Ctrl + Cmd + S` | `sttToggle` |
| 選択テキストを読み上げ (TTS) | `Ctrl + Cmd + T` | `ttsToggle` |

### STT パネルショートカット (カスタマイズ可能)

| 操作 | デフォルト | 設定キー |
|------|-----------|----------|
| 録音 | `Cmd + R` | `sttRecord` |
| 録音停止 | `Cmd + S` | `sttStop` |
| テキスト貼り付け | `Cmd + Return` | `sttPaste` |
| 挿入先選択 | `Cmd + Shift + Return` | `sttSelectTarget` |
| キャンセル | `Cmd + .` | `sttCancel` |

### TTS パネルショートカット (カスタマイズ可能)

| 操作 | デフォルト | 設定キー |
|------|-----------|----------|
| 読み上げ | `Cmd + Return` | `ttsSpeak` |
| 停止 | `Cmd + .` | `ttsStop` |
| 音声を保存 | `Cmd + S` | `ttsSave` |

### 修飾キーのサポート

すべてのパネルショートカットは修飾キーの組み合わせをサポート:
- Command (⌘)
- Shift (⇧)
- Option (⌥)
- Control (⌃)

---

## API キー管理

### ストレージ

- **主要**: macOS キーチェーン (安全、推奨)
- **代替**: 環境変数 (開発専用)

### サポートされる環境変数

```bash
OPENAI_API_KEY
GEMINI_API_KEY
ELEVENLABS_API_KEY
```

### セキュリティに関する注意

- `~/.typetalk.env` 設定ファイルのサポートはセキュリティ上の理由で**削除**
- デバッグログは情報漏洩防止のため `#if DEBUG` でラップ
- API キーはデバッグモードでもログに記録されない

### KeychainService のスレッドセーフティ

```swift
private let lock = NSLock()

func save(key: String, data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    // ... キーチェーン操作
}
```

---

## スレッドセーフティ

### タイマー管理 (MacOSTTS)

非同期タスクを作成する前に、タイマーは同期的に `self` をチェックする必要あり:

```swift
highlightTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
    // 解放された場合にタイマーを即座に無効化するため、最初に self を同期的にチェック
    guard self != nil else {
        timer.invalidate()
        return
    }
    Task { @MainActor [weak self] in
        guard let self = self else { return }
        // ... タイマーロジック
    }
}
```

### クリップボード操作

- クリップボードアクセスにスレッドセーフなロックを使用
- レースコンディション保護を実装
- 外部変更検出によるクリップボード状態の保持
- 貼り付け操作にリトライロジックを追加

### MainActor 分離

非同期でないコンテキストから @MainActor 状態への同期アクセス:

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return MainActor.assumeIsolated {
        // @MainActor プロパティへの安全なアクセス
        let appState = AppState.shared
        // ...
    }
}
```

---

## キャッシュ管理

### TTS ボイスキャッシュ

- `TTSVoiceCache` でプロバイダごとにキャッシュ
- キャッシュデータを使用する前に有効期限チェックが必要:

```swift
if let cached = TTSVoiceCache.shared.getCachedVoices(for: provider),
   !cached.isEmpty,
   !TTSVoiceCache.shared.isCacheExpired(for: provider) {
    return cached
}
return Self.defaultVoices
```

### 一時ファイル

- アプリの起動時と終了時にクリーンアップ
- 場所: システム一時ディレクトリ
- パターン: `typetalk_*` プレフィックス

---

## 権限

### 必要な権限

| 権限 | 用途 | プロンプト表示タイミング |
|------|------|------------------------|
| マイク | STT 録音 | 初回 STT 使用時 |
| アクセシビリティ | グローバルショートカット、テキスト挿入 | 初回起動時 |
| 画面収録 | ウィンドウサムネイル、システム/アプリオーディオ | 関連機能の初回使用時 |

### 権限の処理

- 権限が付与されていない場合、初回起動時にプロンプトを表示
- アクセサリアプリ (Dock アイコンなし) は権限アラートに特別な処理が必要
- 適切なウィンドウアクティベーションのため一時的に `NSApp.setActivationPolicy(.regular)` を使用

---

## UI/UX ガイドライン

### テキストとラベル

- すべての UI テキストは英語 (ツールチップやラベルに日本語は使用しない)
- アプリ全体で一貫した用語を使用

### プロバイダバッジ

- パネルヘッダーに現在のプロバイダを表示
- フォーマット: "Provider: [name]" アクセントカラー背景

### エラー表示

- パネル内のオーバーレイにエラーを表示
- 可能な場合はアクション可能な情報を含める
- 一時的なエラーは自動クリア

### 単語ハイライト (TTS)

- グラデーションハイライト: 現在の単語 + 前後2単語
- アルファ値: 現在=0.45、隣接=0.25、遠い=0.12
- 正確な単語境界検出に CFStringTokenizer を使用

---

## ビルドとリリース

### バージョン管理

- セマンティックバージョニング (MAJOR.MINOR.PATCH) に従う
- リリース前にプロジェクト設定でバージョン番号を更新
- リリースには `v` プレフィックス付きのタグを使用 (例: `v0.1.3`)

### リリースチェックリスト

1. CHANGELOG.md を更新
2. バージョン番号を更新
3. リリース版をビルド (`./scripts/build.sh`)
4. DMG を作成 (`./scripts/create-dmg.sh`)
5. 公証 (`./scripts/notarize.sh`)
6. タグ付きで GitHub リリースを作成
7. リリースに DMG をアップロード

---

## 既知の問題と回避策

### 起動後のアプリアクティベーション

LaunchServices (`open` コマンド) 経由で起動されたアプリは、複数回のアクティベーション試行が必要な場合あり:

```swift
private func activateWindowWithRetry(attempt: Int = 0) {
    guard let window = floatingWindow, attempt < 20 else { return }
    if window.isKeyWindow { return }

    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.activateWindowWithRetry(attempt: attempt + 1)
    }
}
```

### テキストビューのフォーカス

フローティングウィンドウ内の SwiftUI TextEditor は明示的なフォーカス処理が必要:
- `NSWindow.didBecomeKeyNotification` を監視
- ビュー階層内で NSTextView を再帰的に検索
- `window.makeFirstResponder(textView)` を呼び出す

---

*最終更新: 2026-01-13*

# 開発ノート

SpeechDock開発者向けの技術ドキュメントです。

[English](DEVELOPMENT_NOTES.md) | 日本語

## 目次

- [ソースからのビルド](#ソースからのビルド)
- [プロジェクト構成](#プロジェクト構成)
- [アーキテクチャ](#アーキテクチャ)
- [実装詳細](#実装詳細)
- [ビルドとリリース](#ビルドとリリース)
- [既知の問題と回避策](#既知の問題と回避策)

---

## ソースからのビルド

### 前提条件

- Xcode 16.0以降
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Apple Developerアカウント（コード署名と公証用）

### ビルド手順

```bash
# リポジトリをクローン
git clone https://github.com/yohasebe/SpeechDock.git
cd SpeechDock

# Xcodeプロジェクトを生成
xcodegen generate

# Xcodeで開く
open SpeechDock.xcodeproj

# ビルドと実行 (Cmd + R)
```

### 開発用APIキー

開発時は環境変数でAPIキーを設定できます：

```bash
export OPENAI_API_KEY="your-key"
export GEMINI_API_KEY="your-key"
export ELEVENLABS_API_KEY="your-key"
```

注: 製品版ユーザーは設定UIでキーを設定（macOSキーチェーンに保存）。

---

## プロジェクト構成

```
SpeechDock/
├── App/
│   ├── SpeechDockApp.swift      # アプリエントリーポイント
│   ├── AppState.swift         # グローバル状態管理
│   ├── AppDelegate.swift      # アプリライフサイクル
│   ├── StatusBarManager.swift # メニューバー管理
│   └── WindowManager.swift    # ウィンドウ管理
├── Services/
│   ├── TTS/                   # 音声合成実装
│   ├── RealtimeSTT/           # 音声認識実装
│   ├── AudioInputManager.swift
│   ├── AudioOutputManager.swift
│   └── KeychainService.swift
├── Views/
│   ├── MenuBarView.swift
│   ├── FloatingWindow/        # STT/TTSパネル
│   └── Settings/              # 設定ウィンドウ
├── Resources/
│   ├── Info.plist
│   └── Assets.xcassets
└── Scripts/
    ├── build.sh
    ├── create-dmg.sh
    └── notarize.sh
```

---

## アーキテクチャ

### 状態管理

- `AppState`: 全アプリ状態を管理するObservableシングルトン
- 設定はUserDefaultsに永続化
- APIキーはmacOSキーチェーンに保存

### プロバイダパターン

STTとTTSはプロトコルベースのプロバイダパターンを使用：

```swift
protocol TTSService {
    func speak(text: String) async throws
    func availableVoices() -> [TTSVoice]
    func availableModels() -> [TTSModelInfo]
    var audioOutputDeviceUID: String { get set }
}
```

実装: `MacOSTTS`, `OpenAITTS`, `GeminiTTS`, `ElevenLabsTTS`

### ウィンドウレベル階層

ウィンドウレベルは`WindowLevelCoordinator`により動的に管理：

| コンポーネント | レベル | 動作 |
|---------------|--------|------|
| 設定ウィンドウ | `.floating` (3) | 標準フローティングレベル |
| メニューバーポップオーバー | 動的 (`popUpMenu + n`) | 表示時にインクリメント |
| STT/TTSパネル | 動的 (`popUpMenu + n`) | 表示時にインクリメント |
| 保存ダイアログ | `popUpMenu + 500` | 常に最前面 |

**設計原則:** 最後に表示されたパネルが最前面に表示される。
- メニューバーポップオーバー表示中にSTT/TTSパネルを開くと、パネルが上に表示
- STT/TTSパネル表示中にメニューバーをクリックすると、ポップオーバーが上に表示
- 保存ダイアログは常にすべてのパネルより上に表示

**実装詳細:**
- `WindowLevelCoordinator.nextPanelLevel()` レベルをインクリメントして返す
- `WindowLevelCoordinator.reset()` パネルを閉じる際に呼び出し、レベルの無限増加を防止
- 100回のインクリメント後にラップする安全制限（reset()により通常は発生しない）
- `WindowLevelCoordinator.configureSavePanel()` で保存ダイアログをパネルより上に表示

### ウィンドウのアクティベーション

ペースト先ウィンドウをアクティベートする際：
- 最小化されたウィンドウはAccessibility APIで自動的に復元
- `WindowService.unminiaturizeWindowIfNeeded()` が `kAXMinimizedAttribute` をチェックしfalseに設定
- アクセシビリティ権限が必要

### 起動時の最適化

起動時にバックグラウンドでプリフェッチを実行し応答性を向上：
- `prefetchAvailableAppsInBackground()` - App Audioのアプリケーションとアイコンを事前読み込み
- `refreshVoiceCachesInBackground()` - キャッシュ期限切れの場合ElevenLabsの音声リストを事前読み込み

これらの操作はノンブロッキングで、起動時間に影響しない。

---

## 実装詳細

### 設定の永続化

永続化される設定（UserDefaults）：

| 設定 | キー |
|------|-----|
| STTプロバイダ | `selectedRealtimeProvider` |
| STTモデル | `selectedRealtimeSTTModel` |
| TTSプロバイダ | `selectedTTSProvider` |
| TTS音声 | `selectedTTSVoice` |
| TTSモデル | `selectedTTSModel` |
| TTS速度 | `selectedTTSSpeed` |
| STT言語 | `selectedSTTLanguage` |
| TTS言語 | `selectedTTSLanguage` |
| 音声入力ソース | `selectedAudioInputSourceType` |
| マイクデバイス | `selectedAudioInputDeviceUID` |
| 音声出力デバイス | `selectedAudioOutputDeviceUID` |
| VAD最小録音時間 | `vadMinimumRecordingTime` |
| VAD無音検出時間 | `vadSilenceDuration` |
| ペースト後パネルを閉じる | `closePanelAfterPaste` |

セッション限定の設定（永続化されない）：
- `selectedAudioAppBundleID` - アプリオーディオは再起動時にマイクにリセット

システム管理の設定（UserDefaultsに保存されない）：
- `ログイン時起動` - macOS ServiceManagementフレームワーク（SMAppService）で管理、macOS 13.0以降が必要

### STT言語サポート

#### プロバイダ別言語対応

| プロバイダ | 対応言語数 | 自動検出 |
|----------|-----------|---------|
| macOS | システムインストール済みのみ | なし（システムロケール使用） |
| Local Whisper | 99言語 | あり |
| OpenAI Realtime | 50+言語 | あり |
| Gemini Live | 24言語 | あり |
| ElevenLabs Scribe | 90+言語 | あり |

#### 言語選択の設計方針

言語ピッカーには、全対応言語ではなく**厳選された26の主要言語**を表示：

- 英語、日本語、中国語、韓国語、スペイン語、フランス語、ドイツ語、イタリア語、ポルトガル語、ロシア語、アラビア語、ヒンディー語
- オランダ語、ポーランド語、トルコ語、インドネシア語、ベトナム語、タイ語
- ベンガル語、グジャラート語、カンナダ語、マラヤーラム語、マラーティー語、タミル語、テルグ語

**選定理由：**
1. UIの使いやすさ維持（99項目のピッカーは扱いにくい）
2. 最も一般的に使用される言語をカバー
3. リストにない言語は「Auto」検出で対応可能

**プロバイダ別の調整：**
- **macOS**: システムにインストールされた言語のみ表示（`SFSpeechRecognizer.supportedLocales()`で取得）
- **Gemini**: ポルトガル語を除外（Gemini Live APIが非対応）
- **その他**: 共通言語リストをすべて表示

**重要:** ピッカーにない言語でも、「Auto」選択時には認識可能です。ピッカーは精度向上のために言語を明示指定する用途であり、プロバイダの認識能力の制限ではありません。

#### 新しい言語の追加方法

ピッカーに新しい言語を追加するには：

1. `Models/LanguageCode.swift`の`LanguageCode`列挙型にケースを追加
2. 新言語の`displayName`を追加
3. `toLocaleIdentifier()`と`toElevenLabsTTSCode()`にマッピングを追加
4. `commonLanguages`配列に追加（必要に応じてプロバイダ固有の配列にも）

### Local Whisper (WhisperKit) モデルの保存

#### モデルの保存場所

WhisperKitモデルはユーザーのDocumentsフォルダに保存されます：

```
~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/
```

これはWhisperKitのデフォルト保存場所で、WhisperKitを使用するすべてのアプリで共有されます。

#### 利用可能なモデル

| モデル | タイプ | サイズ | 説明 |
|-------|-------|-------|------|
| Tiny | 多言語 | ~39MB | 最速、精度低め |
| Tiny (English) | 英語専用 | ~39MB | 英語に最適化 |
| Base | 多言語 | ~74MB | 高速、良好な精度 |
| Base (English) | 英語専用 | ~74MB | 英語推奨 |
| Small | 多言語 | ~244MB | バランス型 |
| Small (English) | 英語専用 | ~244MB | 英語推奨 |
| Medium | 多言語 | ~769MB | 高精度 |
| Large v2 | 多言語 | ~1.5GB | 非常に高精度 |
| Large v3 | 多言語 | ~1.5GB | 最高精度 |
| Large v3 Turbo | 多言語 | ~800MB | 高速＋高精度 |

#### アプリ削除時の動作

SpeechDockをアンインストールした場合：

| データ | 削除される？ | 場所 |
|-------|------------|------|
| SpeechDock.app | はい | /Applications |
| WhisperKitモデル | **いいえ** | ~/Documents/huggingface/ |
| ユーザー設定 | アンインストーラによる | ~/Library/Preferences |
| APIキー | アンインストーラによる | Keychain |

**重要:** WhisperKitモデルはアプリ削除後も残ります。ディスク容量を回復するには手動での削除が必要です：

```bash
rm -rf ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/
```

**注意:** この場所は他のWhisperKit利用アプリと共有される可能性があります。

### 音声出力デバイス選択

カスタム出力デバイスのサポートにAVAudioEngineを使用：

```swift
// システムデフォルトにはAVAudioPlayer
if outputDeviceUID.isEmpty {
    try playWithAudioPlayer(url: tempURL)
} else {
    // カスタムデバイスにはAVAudioEngine
    try playWithAudioEngine(url: tempURL)
}
```

Core Audio経由で出力デバイスを設定：

```swift
AudioUnitSetProperty(
    audioUnit,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &deviceID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)
```

### パネルライフサイクル

パネルが閉じられたとき：
1. STT: `cancelRecording()`が呼ばれる
2. TTS: `stopTTS()`が呼ばれる
3. ローディング状態: キャンセルされる

Cmd+Qの動作：
- パネル表示中: パネルのみ閉じる
- パネルなし: アプリ終了

STTパネルのペースト動作（`closePanelAfterPaste`設定）：
- **false（デフォルト）**: ペースト後もパネルを開いたまま、フォーカスをパネルに戻す
- **true**: ペースト後にパネルを閉じる（従来の動作）

この設定により、パネルを再度開くことなく複数のテキストをペーストできる。

### スレッドセーフティ

タイマー管理パターン：

```swift
Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
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

同期コンテキストでのMainActor分離：

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return MainActor.assumeIsolated {
        // @MainActorプロパティへの安全なアクセス
    }
}
```

### キーチェーンセキュリティ

```swift
private let lock = NSLock()

func save(key: String, data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    // キーチェーン操作
}
```

- NSLockでスレッドセーフ
- APIキーはログに出力されない
- `~/.speechdock.env`サポートはセキュリティ上削除

### キャッシュ管理

#### TTS音声キャッシュ

音声データはプロバイダごとにキャッシュされ、自動的に有効期限が設定されます：

```swift
if let cached = TTSVoiceCache.shared.getCachedVoices(for: provider),
   !cached.isEmpty,
   !TTSVoiceCache.shared.isCacheExpired(for: provider) {
    return cached
}
return Self.defaultVoices
```

**キャッシュプロパティ：**
- 有効期限: 24時間
- 保存先: UserDefaults
- バージョン: キャッシュフォーマット変更時にインクリメント（自動マイグレーションがトリガー）

**音声品質の保存：**
- `VoiceQuality` enum（`standard`, `enhanced`, `premium`）は `qualityRawValue`（Int）として保存
- キャッシュバージョン2で品質プロパティを追加。古いキャッシュはアップグレード時にクリア
- デコードフォールバック: `qualityRawValue`が欠落している場合は0（standard）にデフォルト

**バックグラウンドキャッシュリフレッシュ：**
- `refreshVoiceCachesInBackground()`は起動時にキャッシュ期限切れの場合ElevenLabs音声をプリロード
- 高速起動を維持するための非ブロッキング操作

#### 一時ファイル

- 場所: システム一時ディレクトリ
- パターン: `tts_*.wav`, `tts_*.mp3`
- クリーンアップ: 作成から5分後

### ElevenLabs STT重複排除

ElevenLabs Scribe APIは、後続の`committed_transcript`メッセージで以前にコミットされたテキストを再送信する場合があります。`ElevenLabsRealtimeSTT`クラスは重複排除ロジックでこれを処理します：

```swift
if committedText.isEmpty {
    committedText = text
} else if !committedText.hasSuffix(text) && !committedText.contains(text) {
    committedText += " " + text
}
// else: 重複をスキップ
```

**重要な注意事項：**
- `hasSuffix`は完全な接尾辞一致をキャッチ
- `contains`はテキスト全体が既に受信済みの場合をキャッチ
- 大文字小文字を区別する比較（意図的）
- "world"がコミット済みの場合、"world again"のような部分的な重複は除外されない

---

## ビルドとリリース

### バージョン管理

以下でバージョンを更新：
- `project.yml` (`MARKETING_VERSION`)
- `Resources/Info.plist` (`CFBundleShortVersionString`)

その後プロジェクトを再生成：

```bash
xcodegen generate
```

### ビルドスクリプト

```bash
# リリースビルド
./scripts/build.sh

# DMG作成
./scripts/create-dmg.sh

# 公証
./scripts/notarize.sh
```

### リリースチェックリスト

1. CHANGELOG.mdを更新
2. project.ymlとInfo.plistでバージョンを更新
3. `xcodegen generate`を実行
4. リリースビルド: `./scripts/build.sh`
5. DMG作成: `./scripts/create-dmg.sh`
6. 公証: `./scripts/notarize.sh`
7. appcast.xmlを新バージョン情報で更新
8. タグ付きでGitHubリリースを作成（例: `v0.1.4`）
9. DMGをアップロード

### 自動アップデート (Sparkle)

SpeechDockは自動アップデートに[Sparkle 2](https://sparkle-project.org/)を使用しています。アップデートはGitHub Releases経由で配信されます。

#### 初期設定（一度だけ）

**1. EdDSA鍵ペアの生成**

```bash
# Sparkleツールをインストール（パッケージ経由でまだの場合）
# generate_keysツールはSparkle.frameworkに含まれています

# 鍵ペアを生成
./Sparkle.framework/Versions/B/Resources/generate_keys

# 出力:
# - 秘密鍵（秘密保持、GitHubシークレットとして保存）
# - 公開鍵（Info.plistのSUPublicEDKeyに追加）
```

**重要:** 秘密鍵は安全に保管してください。アップデートの署名に必要です。

**2. Info.plistの設定**

`Resources/Info.plist`に以下のキーを追加：

```xml
<!-- Sparkle自動アップデート設定 -->
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/yohasebe/speechdock/main/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>YOUR_PUBLIC_KEY_HERE</string>
<key>SUEnableAutomaticChecks</key>
<true/>
```

**3. appcast.xmlの作成**

リポジトリルートに`appcast.xml`を作成：

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>SpeechDock Updates</title>
        <link>https://github.com/yohasebe/speechdock</link>
        <description>Most recent changes with links to updates.</description>
        <language>en</language>
        <item>
            <title>Version 0.1.4</title>
            <pubDate>Mon, 13 Jan 2026 12:00:00 +0000</pubDate>
            <sparkle:version>1</sparkle:version>
            <sparkle:shortVersionString>0.1.4</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="https://github.com/yohasebe/speechdock/releases/download/v0.1.4/SpeechDock.dmg"
                sparkle:edSignature="SIGNATURE_HERE"
                length="FILE_SIZE_IN_BYTES"
                type="application/octet-stream"/>
        </item>
    </channel>
</rss>
```

#### アップデートの署名

リリースごとにDMGファイルに署名：

```bash
# DMGに署名
./Sparkle.framework/Versions/B/Resources/sign_update SpeechDock.dmg

# appcast.xmlで使用するEdDSA署名が出力される
```

#### GitHub Actions連携

リリースワークフローに追加：

```yaml
- name: Sign update for Sparkle
  run: |
    # Sparkleツールをダウンロードまたはキャッシュ版を使用
    SIGNATURE=$(./sign_update SpeechDock.dmg --ed-key-file ${{ secrets.SPARKLE_PRIVATE_KEY }})
    echo "SPARKLE_SIGNATURE=$SIGNATURE" >> $GITHUB_ENV

- name: Update appcast.xml
  run: |
    # 新しいバージョン情報と署名でappcast.xmlを更新
    # スクリプトで自動化することを推奨
```

#### 必要なGitHubシークレット

| シークレット | 説明 |
|-------------|------|
| `SPARKLE_PRIVATE_KEY` | アップデート署名用のEdDSA秘密鍵 |

#### 動作の仕組み

1. アプリは起動時に`SUFeedURL`をチェック（`SUEnableAutomaticChecks`がtrueの場合）
2. Sparkleがアプリのバージョンとappcast.xmlの最新バージョンを比較
3. 新しいバージョンがある場合、ユーザーにアップデートを促す
4. インストール前に`SUPublicEDKey`で署名を検証
5. ユーザーは「アップデートを確認...」メニューで手動チェックも可能

---

## 既知の問題と回避策

### 起動後のアプリアクティベーション

LaunchServices経由で起動されたアプリは複数回のアクティベーション試行が必要：

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

### フローティングウィンドウでのテキストビューフォーカス

SwiftUI TextEditorは明示的なフォーカス処理が必要：

1. `NSWindow.didBecomeKeyNotification`を監視
2. ビュー階層でNSTextViewを検索
3. `window.makeFirstResponder(textView)`を呼び出し

### パネルボタンのサイズ

STT/TTSパネルの`ButtonLabelWithShortcut`コンポーネントは以下のパディング値を使用：

```swift
.padding(.horizontal, 4)
.padding(.vertical, 3)
```

**重要:** これらの値は変更しないでください。適切な視覚バランスのために調整済みです。

### AVAudioEngineの完了ハンドラ

`.dataPlayedBack`完了タイプを使用して、音声再生完了後にハンドラが呼ばれることを保証：

```swift
playerNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
    // 音声が実際に再生完了した時に呼ばれる
}
```

---

*最終更新: 2026-01-14*

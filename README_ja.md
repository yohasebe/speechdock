# TypeTalk

複数のプロバイダに対応した、音声認識 (STT) と音声合成 (TTS) のための macOS メニューバーアプリケーションです。

[English](README.md) | 日本語

## 機能

### 音声認識 (Speech-to-Text)

以下のプロバイダを使用して音声をテキストに変換:

- **macOS ネイティブ** - 内蔵の音声認識機能 (APIキー不要)
- **OpenAI** - Whisper および GPT-4o Transcribe モデル
- **Google Gemini** - Gemini 2.5 Flash
- **ElevenLabs** - Scribe v1

### 音声合成 (Text-to-Speech)

以下のプロバイダを使用してテキストを音声に変換:

- **macOS ネイティブ** - AVSpeechSynthesizer (APIキー不要)
- **OpenAI** - TTS-1, TTS-1 HD, GPT-4o Mini TTS
- **Google Gemini** - Gemini 2.5 Flash TTS
- **ElevenLabs** - Flash v2.5, Multilingual v2

### その他の機能

- STT/TTS 用のグローバルキーボードショートカット
- メニューバーからすべての機能にクイックアクセス
- リアルタイム文字起こし表示用のフローティングウィンドウ
- テキスト編集機能付きの TTS フローティングウィンドウ
- macOS キーチェーンによる API キー管理
- TTS 再生速度の調整
- プロバイダごとの音声・モデル選択
- ログイン時の自動起動オプション
- 二重起動防止

## 動作環境

- macOS 14.0 (Sonoma) 以降
- クラウドプロバイダの場合: OpenAI、Google Gemini、または ElevenLabs の API キー

## インストール

1. [Releases](https://github.com/yohasebe/TypeTalk/releases) ページから最新の `.dmg` ファイルをダウンロード
2. DMG ファイルを開く
3. TypeTalk を Applications フォルダにドラッグ
4. Applications から TypeTalk を起動
5. プロンプトが表示されたら必要な権限を許可 (マイク、アクセシビリティ)

## 使い方

### キーボードショートカット

| 操作 | デフォルトショートカット |
|------|--------------------------|
| 録音開始/停止 (STT) | `Ctrl + Cmd + S` |
| 選択テキストを読み上げ (TTS) | `Ctrl + Cmd + T` |

ショートカットは 設定 > ショートカット でカスタマイズできます。

### STT パネルの操作

| 操作 | ショートカット |
|------|----------------|
| 録音停止 | `Cmd + S` |
| テキスト挿入 | `Cmd + Return` |
| すべてコピー | (ボタンをクリック) |
| キャンセル | `Cmd + .` |

### TTS パネルの操作

| 操作 | ショートカット |
|------|----------------|
| 読み上げ | `Cmd + Return` |
| 一時停止/再開 | `Cmd + P` |
| 停止 | `Cmd + .` |
| 閉じる | `Cmd + W` |

### メニューバー

メニューバーの TypeTalk アイコンをクリックして:

- STT 録音の開始/停止
- TTS パネルを開く
- 設定にアクセス
- 現在のプロバイダ状態を確認

## 設定

### API キー

1. 設定 > API Keys を開く
2. 使用したいプロバイダの API キーを入力:
   - **OpenAI**: [OpenAI Platform](https://platform.openai.com/api-keys) でキーを取得
   - **Google Gemini**: [Google AI Studio](https://aistudio.google.com/apikey) でキーを取得
   - **ElevenLabs**: [ElevenLabs](https://elevenlabs.io/app/settings/api-keys) でキーを取得

API キーは macOS キーチェーンに安全に保存されます。

### 環境変数

環境変数で API キーを設定することもできます:

```bash
export OPENAI_API_KEY="your-openai-key"
export GEMINI_API_KEY="your-gemini-key"
export ELEVENLABS_API_KEY="your-elevenlabs-key"
```

### 設定項目

- **General**: STT/TTS プロバイダ、モデル、音声、再生速度の選択
- **Shortcuts**: グローバルキーボードショートカットのカスタマイズ
- **API Keys**: クラウドプロバイダの API キー管理

### ログイン時の自動起動

設定 > General で「Launch at Login」を有効にすると、ログイン時に TypeTalk が自動的に起動します。

## ソースからのビルド

### 前提条件

- Xcode 15.0 以降
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (オプション、プロジェクト生成用)

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

## 権限

TypeTalk は以下の権限が必要です:

- **マイク**: 音声認識用
- **アクセシビリティ**: グローバルキーボードショートカットとテキスト選択用

システム設定 > プライバシーとセキュリティ で権限を許可してください。

## トラブルシューティング

### STT が動作しない

1. マイクの権限が許可されていることを確認
2. 選択したプロバイダの API キーが有効か確認 (クラウドプロバイダの場合)
3. macOS ネイティブプロバイダに切り替えてテスト

### TTS が動作しない

1. 選択したプロバイダの API キーが有効か確認 (クラウドプロバイダの場合)
2. macOS ネイティブプロバイダに切り替えてテスト
3. オーディオ出力がミュートされていないことを確認

### キーボードショートカットが反応しない

1. アクセシビリティの権限が許可されていることを確認
2. 他のアプリケーションとの競合を確認
3. 設定でショートカットをデフォルトにリセット

## ライセンス

このプロジェクトは Apache License 2.0 でライセンスされています。詳細は [LICENSE](LICENSE) ファイルを参照してください。

## 作者

長谷部陽一郎

## コントリビューション

コントリビューションを歓迎します！お気軽に Pull Request を送ってください。

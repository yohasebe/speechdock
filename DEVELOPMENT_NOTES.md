# TypeTalk Development Notes

このファイルはgitにコミットしない開発メモです。

---

## macOS 26 / iOS 26 新機能調査結果 (2025-01)

### 1. SpeechAnalyzer オプション一覧

#### reportingOptions（結果配信オプション）
| オプション | 説明 | TypeTalkへの適用 |
|-----------|------|-----------------|
| `.volatileResults` | 中間結果をリアルタイムで取得 | ✅ **実装済み** |
| `.fastResults` | より高速な結果取得 | ✅ **実装済み** |

#### attributeOptions（メタデータオプション）
| オプション | 説明 | TypeTalkへの活用 |
|-----------|------|-----------------|
| `.audioTimeRange` | 単語ごとのタイムスタンプ | 字幕表示、タイミング同期に有用 |

#### presets（プリセット）
| プリセット | 説明 | 用途 |
|-----------|------|------|
| `.progressiveLiveTranscription` | リアルタイム音声用 | 現在の手動設定の代わりに使用可能 |
| `.offlineTranscription` | ファイル処理用 | 音声ファイル変換機能に有用 |

---

### 2. DictationTranscriber vs SpeechTranscriber

| 機能 | DictationTranscriber | SpeechTranscriber |
|------|---------------------|-------------------|
| **句読点** | 自動挿入 ✅ | 最小限 |
| **文構造** | 会話形式で整形 | 生テキスト |
| **最適用途** | ドキュメント、メール | コマンド、キーワード検索 |
| **デバイス対応** | 幅広い（フォールバック） | 新しいデバイスのみ |

**TypeTalkへの提案**: DictationTranscriberに切り替えると、句読点が自動挿入され、より自然な文章になる可能性あり

---

### 3. SpeechDetector（音声活動検出 / VAD）

```swift
let speechDetector = SpeechDetector(
    detectionOptions: .init(sensitivityLevel: .medium),
    reportResults: false
)
```

**TypeTalkへの活用**:
- 自動録音開始/停止
- 無音検出による発話終了判定
- 現在のVAD実装を置き換え可能

⚠️ **注意**: 現在バグあり（SpeechModuleプロトコルに準拠していない）。次のアップデートで修正予定。

---

### 4. Foundation Models Framework（オンデバイスLLM）

```swift
let session = LanguageModelSession()
let result = try await session.respond(to: "Summarize this text...")
```

**TypeTalkへの活用**:
- **音声の要約**: 長い発話を自動要約
- **テキスト整形**: 文法修正、言い換え
- **コンテンツタグ付け**: 会話のカテゴリ分類
- **完全オフライン**: プライバシー保護、APIコスト不要

#### Guided Generation（型安全な構造化出力）
```swift
@Generable
struct TranscriptionSummary {
    let summary: String
    let keyPoints: [String]
    @Guide(.anyOf(["question", "statement", "command"]))
    let intentType: String
}
```

#### Tool Calling
```swift
struct FindRestaurants: Tool {
    let name = "findRestaurants"
    let description = "Find nearby restaurants"

    @Generable
    struct Arguments {
        let cuisine: String
        let maxDistance: Int
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        // Implementation
    }
}
```

**要件**: Apple Intelligence対応デバイス、iOS 26+ / macOS 26+

---

### 5. Speaker Diarization（話者識別）

Apple純正のSpeechAnalyzerには話者識別機能がないが、サードパーティで対応可能：

- **FluidAudio**: CoreMLベースの話者識別 (https://github.com/FluidInference/FluidAudio)
- **SpeakerKit (Argmax)**: 10MB以下の軽量モデル

複数人の会話を「Speaker 1」「Speaker 2」と区別可能

---

### 6. Personal Voice API

ユーザーが作成したカスタム音声でTTS可能：

```swift
let personalVoice = AVSpeechSynthesisVoice(identifier: "com.apple.speech.synthesis.voice.personal")
```

**TypeTalkへの活用**: アクセシビリティ機能として、ユーザー固有の音声でTTS

---

### 7. パフォーマンス比較

| ツール | 34分ファイル処理時間 |
|--------|---------------------|
| **SpeechAnalyzer** | 45秒 |
| MacWhisper (Large V3) | 1分41秒 |
| VidCap | 1分55秒 |

**2.2倍高速** で Whisper と同等の精度

---

### 優先度の高い実装候補

1. **DictationTranscriber** - 句読点自動挿入で品質向上
2. **SpeechDetector** - VAD改善（バグ修正待ち）
3. **Foundation Models** - オンデバイス要約機能
4. **`.audioTimeRange`** - 字幕タイミング同期

---

## 参考リンク

- [WWDC25 - SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [iOS 26 SpeechAnalyzer Guide](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide)
- [DEV Community - SpeechAnalyzer](https://dev.to/arshtechpro/wwdc-2025-the-next-evolution-of-speech-to-text-using-speechanalyzer-6lo)
- [Foundation Models Framework](https://www.createwithswift.com/exploring-the-foundation-models-framework/)
- [Apple Developer Forums - SpeechDetector](https://developer.apple.com/forums/thread/797544)
- [FluidAudio - Speaker Diarization](https://github.com/FluidInference/FluidAudio)
- [Create with Swift - Speech-to-Text](https://www.createwithswift.com/implementing-advanced-speech-to-text-in-your-swiftui-app/)

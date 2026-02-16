---
layout: default
title: ホーム
nav_exclude: true
search_exclude: true
lang: ja
---

<p align="right"><a href="index.html">English</a></p>

<p align="center">
  <img src="images/icon.png" alt="SpeechDock" width="128" height="128">
</p>

# SpeechDock
{: .text-center }

**Speak and listen, from anywhere on your Mac.**
{: .text-center .fs-6 }

[ダウンロード](https://github.com/yohasebe/SpeechDock/releases){: .btn .btn-primary .mr-2 }
[GitHub](https://github.com/yohasebe/SpeechDock){: .btn }
{: .text-center }

---

## SpeechDockとは？

**画面上のあらゆるテキストを音声に** — 選択テキスト、直接入力、ペースト、画面からのOCRキャプチャ。見えるテキストなら、SpeechDockが読み上げます。

**Macのあらゆる音声をテキストに** — マイクからの声、システム全体の音声、特定アプリの音声。Macが聞ける音なら、SpeechDockがリアルタイムで文字起こしします。

メニューバーに常駐し、グローバルホットキーでどこからでもアクセス可能。インストール後すぐに使え、APIキーや追加ダウンロードは不要です。

---

## アーキテクチャ

<p align="center">
  <img src="images/architecture.png" alt="SpeechDock アーキテクチャ" style="max-width: 720px;">
</p>

---

## 主な機能

### 音声認識 (STT)
- **あらゆる音声ソース** — マイク、システム音声、特定のアプリ音声
- **リアルタイム文字起こし** — 話しながらテキストを確認
- **字幕モード** — プレゼンや会議用のフローティングオーバーレイ
- **クイック入力** — フローティングマイクボタンで即座に音声入力

### 音声合成 (TTS)
- **あらゆるテキストソース** — 直接入力、ペースト、他アプリで選択、画面からOCR
- **自然な音声** — macOS内蔵またはクラウドプロバイダの音声
- **速度調整** — リアルタイムで再生速度を調整（0.5x〜2.0x）
- **音声保存** — 音声をファイルにエクスポート

### 翻訳
- **オンデバイス翻訳** — APIキー不要（macOS 26以降）
- **18以上の言語** — 主要言語間で翻訳
- **TTS連携** — 翻訳テキストを自動的に読み上げ

### クラウドプロバイダ（オプション）
- **OpenAI** — GPT-4o Transcribe、GPT-4o Mini TTS
- **Google Gemini** — Gemini 2.5 Flash（STT/TTS）
- **ElevenLabs** — Scribe v2（STT）、Eleven v3（TTS）
- **Grok (xAI)** — Grok 2（STT/TTS）

---

## 動作環境

- macOS 14.0 (Sonoma) 以降
- Apple Silicon Mac (M1/M2/M3/M4)

---

## ドキュメント

| ページ | 説明 |
|:-------|:-----|
| [基本機能](basics_ja.html) | インストール、STT、TTS、OCR、字幕、ショートカット |
| [高度な機能](advanced_ja.html) | クラウドプロバイダ、APIキー、ファイル文字起こし |
| [AppleScript](applescript_ja.html) | 自動化とスクリプティング |

---

## スクリーンショット

<figure>
  <img src="images/stt-panel.png" alt="STT Panel" style="max-width: 600px;">
  <figcaption>音声認識パネル</figcaption>
</figure>

<figure>
  <img src="images/tts-panel.png" alt="TTS Panel" style="max-width: 600px;">
  <figcaption>音声合成パネル</figcaption>
</figure>

<figure>
  <img src="images/quick-transcription.png" alt="Quick Transcription" style="max-width: 600px;">
  <figcaption>クイック入力 — ボタンをクリックすると録音が停止し、文字起こしテキストがカーソル位置にペーストされます</figcaption>
</figure>

<figure>
  <img src="images/subtitle-overlay.png" alt="Subtitle Mode" style="max-width: 100%;">
  <figcaption>字幕モード — リアルタイム文字起こしをフローティング字幕として表示</figcaption>
</figure>

---

## ライセンス

SpeechDockは[Apache License 2.0](https://github.com/yohasebe/SpeechDock/blob/main/LICENSE)の下で公開されています。

// The figures of the smaller tools, drawn with the parts of generate-doc-figures.swift.

import AppKit

let toolFigures: [Figure] = [
    ("quick-transcription", quickTranscription),
    ("translation-controls", translationControls),
    ("select-paste-target", selectPasteTarget),
    ("ocr-selection", ocrSelection),
    ("shortcuts", shortcutsOverlay),
    ("file-transcription", fileTranscription),
]

/// Symbols these figures use besides the shared ones, on the same 16 × 16 grid.
let toolIcons: [String: String] = [
    "checkmark": #"<path d="M3.5 8.5l3 3 6-7" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
    "arrow.up.arrow.down": #"<path d="M5 13V3M2.5 5.5L5 3l2.5 2.5M11 3v10M8.5 10.5L11 13l2.5-2.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
    "pointer": #"<path d="M3 1.5v11.5l3-2.8 2 4.3 2-.9-2-4.2h4.2z" fill="black" stroke="white" stroke-width="0.9" stroke-linejoin="round"/>"#,
]

// MARK: - Reading the app

/// A `static let` constant, as in `static let hudWidth: CGFloat = 320`.
func constantValue(_ name: String, in path: String) -> CGFloat {
    let text = source(path)
    let regex = try! NSRegularExpression(pattern: #"static let \#(name): \w+ = ([0-9.]+)"#)
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let value = Double(text[Range(match.range(at: 1), in: text)!]) else { fail("\(path) has no \(name)") }
    return CGFloat(value)
}

/// One panel shortcut of the shortcut list.
struct PanelShortcut {
    let name: String
    let shortcut: String
}

/// The panel shortcuts of one category, in ShortcutAction's order, with their
/// names and default shortcuts as Models/KeyboardShortcutSettings.swift defines them.
func panelShortcuts(_ strings: Strings, category: String) -> [PanelShortcut] {
    let path = "Models/KeyboardShortcutSettings.swift"
    let text = source(path)
    func block(after start: String, until end: String) -> String {
        guard let from = text.range(of: start), let to = text.range(of: end, range: from.upperBound..<text.endIndex) else { fail("\(path) has no \(start)") }
        return String(text[from.upperBound..<to.lowerBound])
    }
    func matches(_ pattern: String, in body: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { match in
            (1..<match.numberOfRanges).map { String(body[Range(match.range(at: $0), in: body)!]) }
        }
    }
    let cases = matches(#"case (\w+) = ""#, in: block(after: "enum ShortcutAction", until: "var displayName")).map { $0[0] }
    let names = Dictionary(uniqueKeysWithValues: matches(#"case \.(\w+): return NSLocalizedString\("([^"]+)""#, in: block(after: "var displayName", until: "var category")).map { ($0[0], $0[1]) })
    var categories: [String: String] = [:]
    for match in matches(#"case ([.\w, ]+):\s*return "([^"]+)""#, in: block(after: "var category", until: "var defaultShortcut")) {
        for name in match[0].split(separator: ",") { categories[name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")] = match[1] }
    }
    let defaults = Dictionary(uniqueKeysWithValues: matches(#"case \.(\w+):\s*(?://[^\n]*\s*)*return CustomShortcut\(([^\n]*)\)\n"#, in: block(after: "var defaultShortcut", until: "/// Manager for keyboard")).map { ($0[0], $0[1]) })
    let keyCodes = Dictionary(uniqueKeysWithValues: matches(#"case "(\w)": return (kVK_\w+)"#, in: text).map { ($0[0], $0[1]) })
    let keyNames = Dictionary(matches(#"case (kVK_\w+): return "([^"]+)""#, in: text).map { ($0[0], $0[1]) }) { first, _ in first }

    return cases.filter { categories[$0] == category }.map { action in
        guard let name = names[action], let arguments = defaults[action] else { fail("\(path) has no name or default for \(action)") }
        let code: String?
        if let key = matches(#"key: "(\w)""#, in: arguments).first?[0] {
            code = keyCodes[key]
        } else {
            code = matches(#"keyCode: (kVK_\w+)"#, in: arguments).first?[0]
        }
        guard let code, let key = keyNames[code] else { fail("\(path): cannot read the default of \(action)") }
        return PanelShortcut(name: strings.label(name, in: path), shortcut: modifierSymbols(arguments) + key)
    }
}

/// A translated format string whose source interpolates into a literal, as in
/// `Text("Press ESC or \(shortcut) to dismiss")`.
func format(_ strings: Strings, key: String, shownAs literal: String, in view: String, _ argument: String) -> String {
    guard source(view).contains(literal) else { fail("\(view) no longer shows \(literal)") }
    guard let value = strings.table[key] else { fail("\(strings.language).lproj has no \"\(key)\"") }
    return value.replacingOccurrences(of: "%@", with: argument)
}

// MARK: - Drawing helpers

let monospaced = "ui-monospace, 'SF Mono', Menlo, monospace"

func monospacedWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    ceil(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight)]).size().width)
}

/// Monospaced text whose line box is centered on `centerY`.
func monospacedText(_ svg: SVG, _ text: String, x: CGFloat, centerY: CGFloat, size: CGFloat, weight: Int = 400, color: String) {
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight >= 500 ? .medium : .regular)
    let baseline = centerY + (font.ascender + font.descender) / 2
    svg.add(#"<text x="\#(f(x))" y="\#(f(baseline))" font-family="\#(monospaced)" font-size="\#(f(size))" font-weight="\#(weight)" fill="\#(color)">\#(xml(text))</text>"#)
}

/// A soft, abstract desktop behind a figure.
func desktop(_ svg: SVG, width: CGFloat, height: CGFloat) {
    svg.definitions.append(##"<linearGradient id="tool-desktop" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5d7fb4"/><stop offset="1" stop-color="#8aa3cc"/></linearGradient>"##)
    svg.rect(0, 0, width, height, radius: 0, fill: "url(#tool-desktop)")
}

// MARK: - Figures

/// The floating mic button while recording, with its transcription HUD above it.
func quickTranscription(_ strings: Strings) -> String {
    let constants = "Views/FloatingMicButton/FloatingMicButtonManager.swift"
    let hud = "Views/FloatingMicButton/FloatingMicTextHUD.swift"
    let buttonSize = constantValue("buttonSize", in: constants)
    let hudWidth = constantValue("hudWidth", in: constants), hudHeight = constantValue("hudHeight", in: constants)
    let fontSize = constantValue("hudFontSize", in: constants), lineHeight = constantValue("hudLineHeight", in: constants)
    let text = sample(strings,
        en: "Let's meet on Friday at three and go over the draft together.",
        ja: "金曜の3時に集まって、下書きを一緒に見直しましょう。")

    let canvasWidth: CGFloat = 880, canvasHeight: CGFloat = 360
    let svg = SVG()
    desktop(svg, width: canvasWidth, height: canvasHeight)

    // The app that receives the text: a plain document window with the cursor in it
    let doc = (x: CGFloat(32), y: CGFloat(32), w: CGFloat(440), h: CGFloat(296))
    svg.rect(doc.x, doc.y, doc.w, doc.h, radius: 10, fill: Color.white, filter: "window-shadow")
    svg.add(##"<path d="M\##(f(doc.x)) \##(f(doc.y + 28))h\##(f(doc.w))" stroke="#000" stroke-opacity="0.08"/>"##)
    for (index, color) in ["#d9d9dc", "#d9d9dc", "#d9d9dc"].enumerated() {
        svg.add(##"<circle cx="\##(f(doc.x + 16 + CGFloat(index) * 18))" cy="\##(f(doc.y + 14))" r="5.5" fill="\##(color)"/>"##)
    }
    svg.add(##"<path d="M\##(f(doc.x + 24)) \##(f(doc.y + 48))v20" stroke="#1d1d1f" stroke-width="1.5"/>"##)

    // The HUD, above the button
    let hudX = doc.x + doc.w + 40, hudY: CGFloat = 40
    svg.rect(hudX, hudY, hudWidth, hudHeight, radius: 12, fill: "#000", opacity: 0.85, filter: "window-shadow")
    let headerY = hudY + 12 + Style.callout.lineHeight / 2
    var x = hudX + 16
    svg.add(##"<circle cx="\##(f(x + 4))" cy="\##(f(headerY))" r="4" fill="#ff3b30"/>"##)
    x += 8 + 6
    x += svg.text(strings.label("Recording...", in: hud), x: x, centerY: headerY, .sized(12, .regular), color: "#fff", opacity: 0.8) + 6
    let stop = strings.label("%@ to stop", in: hud).replacingOccurrences(of: "%@", with: defaultShortcut("quickTranscriptionDefault"))
    svg.text(stop, x: x, centerY: headerY, .sized(12, .regular), color: "#fff", opacity: 0.8)
    let textStyle = Style.sized(fontSize, .medium)
    for (index, line) in wrap(text, textStyle, limit: (hudWidth - 32) * 0.98).prefix(4).enumerated() {
        svg.text(line, x: hudX + 16, centerY: headerY + Style.callout.lineHeight / 2 + 8 + lineHeight * (CGFloat(index) + 0.5), textStyle, color: "#fff", opacity: 0.9)
    }

    // The button: red while recording, with its pulse ring
    let cx = hudX + hudWidth / 2, cy = hudY + hudHeight + 10 + buttonSize / 2
    let inner = (buttonSize - 4) / 2
    svg.add(##"<circle cx="\##(f(cx))" cy="\##(f(cy))" r="\##(f(inner * 1.25))" fill="none" stroke="#ff3b30" stroke-opacity="0.35" stroke-width="2"/>"##)
    svg.add(##"<circle cx="\##(f(cx))" cy="\##(f(cy))" r="\##(f(buttonSize / 2))" fill="#f4f4f6" fill-opacity="0.85" filter="url(#control-shadow)"/>"##)
    svg.add(##"<circle cx="\##(f(cx))" cy="\##(f(cy))" r="\##(f(inner))" fill="#ff3b30" fill-opacity="0.9" stroke="#ff3b30" stroke-width="1.5"/>"##)
    svg.icon("stop.fill", x: cx - 9, centerY: cy, size: 18, color: Color.white)

    return svg.document(width: canvasWidth, height: canvasHeight, title: strings.label("Quick Transcription", in: "Views/ShortcutHUD/ShortcutHUDView.swift"))
}

/// The TTS panel showing a translation, with the Original button to go back.
func translationControls(_ strings: Strings) -> String {
    let view = "Views/FloatingWindow/TTSFloatingView.swift"
    // The panel shows the translation; the original was in the other language.
    let text = sample(strings,
        en: "どのアプリでも文字を選んでショートカットを押すと、SpeechDock が読み上げます。",
        ja: "Select text in any app and press the shortcut, and SpeechDock reads it aloud.")
    let svg = SVG()
    panelSurface(svg, height: panelHeight)
    ttsHeader(svg, strings)
    textArea(svg, top: panelAreaTop, height: panelAreaHeight, text: text, fontSize: 18, tint: Color.blue, eraserEnabled: false)
    translationRow(svg, strings, centerY: panelTranslationY, target: languages(strings).target, button: .original)

    let y = panelActionY
    var x = margin + panelPad + 8
    svg.icon("text.viewfinder", x: x, centerY: y, size: 14, color: Color.secondary)
    x += 14 + 4
    x += svg.text(strings.label("OCR", in: view), x: x, centerY: y, .callout, color: Color.secondary) + 8 + 12
    svg.text(countText(strings, text), x: x, centerY: y, .callout, color: Color.secondary)
    actionButtons(svg, centerY: y, [
        (strings.label("Speak", in: view), "speaker.wave.2.fill", true),
        (strings.label("Save Audio", in: view), "square.and.arrow.down", false),
    ])
    return svg.document(width: panelWidth + margin * 2, height: panelHeight + margin * 2, title: strings.label("Translation", in: "Views/Settings/SettingsCategory.swift"))
}

/// The window selector the STT panel's Target button opens.
func selectPasteTarget(_ strings: Strings) -> String {
    let view = "Views/FloatingWindow/TranscriptionFloatingView.swift"
    let text = sample(strings,
        en: "Thanks for the update. I'll review the draft this afternoon and send my comments by tomorrow.",
        ja: "ご連絡ありがとうございます。今日の午後に下書きを確認し、明日までにコメントを送ります。")
    // Windows of macOS's own apps, with neutral titles
    let windows: [(app: String, title: String, tint: String)] = strings.language == "ja"
        ? [("テキストエディット", "週次報告", "#8e9aaf"), ("メモ", "アイデア", "#c9a227"), ("メール", "新規メッセージ", "#3d8bfd")]
        : [("TextEdit", "Weekly Update", "#8e9aaf"), ("Notes", "Ideas", "#c9a227"), ("Mail", "New Message", "#3d8bfd")]

    let popoverWidth: CGFloat = 500 + 32, popoverHeight: CGFloat = 400 + 32
    let svg = SVG()
    panelSurface(svg, height: panelHeight)
    sttHeader(svg, strings)
    textArea(svg, top: panelAreaTop, height: panelAreaHeight, text: text, fontSize: 18)
    translationRow(svg, strings, centerY: panelTranslationY, target: languages(strings).target, button: .translate(enabled: true))
    let group = targetGroup(svg, strings, centerY: panelActionY, selected: true, expanded: true, pasteEnabled: true)
    svg.text(countText(strings, text), x: margin + panelPad + group.width + 8, centerY: panelActionY, .callout, color: Color.secondary)
    actionButtons(svg, centerY: panelActionY, [
        (strings.label("Record", in: view), "mic.fill", true),
        (strings.label("Save Text", in: view), "square.and.arrow.down", false),
        (strings.label("Copy", in: view), "doc.on.doc", false),
    ])

    // The popover, its arrow pointing at the Target button
    let arrowX = group.targetCenter
    let top = panelActionY + 13 + 12
    let left = max(margin - 8, arrowX - 90)
    svg.add(##"<path d="M\##(f(left + 12)) \##(f(top))H\##(f(arrowX - 11))L\##(f(arrowX)) \##(f(top - 11))L\##(f(arrowX + 11)) \##(f(top))H\##(f(left + popoverWidth - 12))a12 12 0 0 1 12 12V\##(f(top + popoverHeight - 12))a12 12 0 0 1-12 12H\##(f(left + 12))a12 12 0 0 1-12-12V\##(f(top + 12))a12 12 0 0 1 12-12z" fill="#f6f6f6" stroke="#000" stroke-opacity="0.12" filter="url(#window-shadow)"/>"##)

    // The 500 × 400 frame centers its content vertically.
    let contentHeight = 300 + 8 + Style.callout.lineHeight
    let contentX = left + 16, contentY = top + 16 + (400 - contentHeight) / 2
    let column: CGFloat = (500 - 8) / 2
    // Left: the focused window's preview
    let bubbleHeight: CGFloat = 8 + 150 + 4 + Style.callout.lineHeight + 8
    svg.rect(contentX, contentY, column, bubbleHeight, radius: 12, fill: Color.window, filter: "control-shadow")
    let thumb = (x: contentX + 8, y: contentY + 8, w: column - 16, h: CGFloat(150))
    svg.rect(thumb.x, thumb.y, thumb.w, thumb.h, radius: 8, fill: Color.white, stroke: "#000", strokeOpacity: 0.1)
    svg.add(##"<path d="M\##(f(thumb.x)) \##(f(thumb.y + 18))h\##(f(thumb.w))" stroke="#000" stroke-opacity="0.08"/>"##)
    for (index, lineWidth) in ([0.45, 0.9, 0.82, 0.88, 0.6, 0.85, 0.7] as [CGFloat]).enumerated() {
        let y = thumb.y + 32 + CGFloat(index) * 14 + (index > 0 ? 6 : 0)
        svg.rect(thumb.x + 14, y, (thumb.w - 28) * lineWidth, index == 0 ? 7 : 5, radius: 2, fill: "#000", opacity: index == 0 ? 0.35 : 0.15)
    }
    let caption = windows[0].app
    svg.text(caption, x: contentX + (column - width(caption, .callout)) / 2, centerY: thumb.y + thumb.h + 4 + Style.callout.lineHeight / 2, .callout, color: Color.secondary)

    // Right: the windows, the selected one focused
    let listX = contentX + column + 8
    svg.rect(listX, contentY, column, 300, radius: 8, fill: Color.window, filter: "window-shadow")
    for (index, window) in windows.enumerated() {
        let rowY = contentY + 8 + 4 + CGFloat(index) * (42 + 2)
        let rowX = listX + 8, rowWidth = column - 16
        if index == 0 { svg.rect(rowX, rowY, rowWidth, 42, radius: 4, fill: Color.accent, opacity: 0.2) }
        let cy = rowY + 21
        appIcon(svg, x: rowX + 8, centerY: cy, size: 28, tint: window.tint)
        svg.text(window.app, x: rowX + 8 + 28 + 8, centerY: cy - 8, .calloutMedium, color: Color.label)
        svg.text(window.title, x: rowX + 8 + 28 + 8, centerY: cy + 8, .callout, color: Color.secondary)
        if index == 0 { svg.icon("checkmark", x: rowX + rowWidth - 8 - 14, centerY: cy, size: 14, color: Color.accent) }
    }

    let hint = strings.label("Use arrow keys to preview", in: view)
    let hintY = contentY + 300 + 8 + Style.callout.lineHeight / 2
    let hintWidth = 12 + 4 + width(hint, .callout)
    let hintX = left + (popoverWidth - hintWidth) / 2
    svg.icon("arrow.up.arrow.down", x: hintX, centerY: hintY, size: 12, color: Color.secondary)
    svg.text(hint, x: hintX + 16, centerY: hintY, .callout, color: Color.secondary)

    let height = top + popoverHeight + margin
    return svg.document(width: panelWidth + margin * 2, height: height, title: strings.label("Select Target", in: "Models/KeyboardShortcutSettings.swift"))
}

/// Dragging out a screen region for OCR, over abstract screen content.
func ocrSelection(_ strings: Strings) -> String {
    let canvasWidth: CGFloat = 560, canvasHeight: CGFloat = 360
    let svg = SVG()
    // Screen content: a page of text drawn as bars
    svg.rect(0, 0, canvasWidth, canvasHeight, radius: 0, fill: "#f4f4f2")
    svg.rect(40, 30, 220, 14, radius: 3, fill: "#000", opacity: 0.55)
    let widths: [CGFloat] = [440, 410, 452, 380, 0, 430, 446, 398, 420, 300]
    for (index, w) in widths.enumerated() where w > 0 {
        svg.rect(40, 70 + CGFloat(index) * 22, w, 9, radius: 2, fill: "#000", opacity: 0.28)
    }

    // The overlay dims everything outside the selection
    let rect = (x: CGFloat(28), y: CGFloat(60), w: CGFloat(476), h: CGFloat(240))
    svg.add(##"<path d="M0 0H\##(f(canvasWidth))V\##(f(canvasHeight))H0Z M\##(f(rect.x)) \##(f(rect.y))v\##(f(rect.h))h\##(f(rect.w))v-\##(f(rect.h))Z" fill="#000" fill-opacity="0.3" fill-rule="evenodd"/>"##)
    svg.rect(rect.x, rect.y, rect.w, rect.h, radius: 0, fill: Color.blue, opacity: 0.2)
    svg.add(##"<rect x="\##(f(rect.x))" y="\##(f(rect.y))" width="\##(f(rect.w))" height="\##(f(rect.h))" fill="none" stroke="#fff" stroke-width="1.5" stroke-dasharray="5 3"/>"##)
    for (cx, cy) in [(rect.x, rect.y), (rect.x + rect.w, rect.y), (rect.x, rect.y + rect.h), (rect.x + rect.w, rect.y + rect.h)] {
        svg.add(##"<circle cx="\##(f(cx))" cy="\##(f(cy))" r="3" fill="#fff"/>"##)
    }

    // The size label under the selection, as the overlay draws it
    // The overlay pads the label with a space on each side.
    let label = "\(Int(rect.w)) × \(Int(rect.h))"
    let space = monospacedWidth(" ", size: 12, weight: .medium)
    let labelWidth = space + monospacedWidth(label, size: 12, weight: .medium) + space
    let labelHeight: CGFloat = 16
    let labelX = rect.x + rect.w / 2 - labelWidth / 2, labelY = rect.y + rect.h + 8
    svg.rect(labelX, labelY, labelWidth, labelHeight, radius: 0, fill: "#000", opacity: 0.7)
    monospacedText(svg, label, x: labelX + space, centerY: labelY + labelHeight / 2, size: 12, weight: 500, color: "#fff")

    return svg.document(width: canvasWidth, height: canvasHeight, title: strings.label("OCR Region to TTS", in: "Views/MenuBarView.swift"))
}

/// The keyboard shortcut list, with the default shortcuts.
func shortcutsOverlay(_ strings: Strings) -> String {
    let view = "Views/ShortcutHUD/ShortcutHUDView.swift"
    let global = [
        ("Toggle STT Panel", "sttDefault"), ("Toggle TTS Panel", "ttsDefault"), ("OCR Region to TTS", "ocrDefault"),
        ("Toggle Subtitle Mode", "subtitleDefault"), ("Quick Transcription", "quickTranscriptionDefault"), ("Show Shortcuts", "shortcutHUDDefault"),
    ].map { PanelShortcut(name: strings.label($0.0, in: view), shortcut: defaultShortcut($0.1)) }
    let columns: [[(title: String, items: [PanelShortcut])]] = [
        [(strings.label("Global Hotkeys", in: view), global),
         (strings.label("STT Panel", in: view), panelShortcuts(strings, category: "STT Panel"))],
        [(strings.label("TTS Panel", in: view), panelShortcuts(strings, category: "TTS Panel")),
         (strings.label("Common", in: view), panelShortcuts(strings, category: "Common"))],
    ]

    let nameStyle = Style.sized(13, .regular)
    let rowHeight: CGFloat = 4 + max(nameStyle.lineHeight, 21) + 4
    func badgeWidth(_ shortcut: String) -> CGFloat { 7 + monospacedWidth(shortcut, size: 12) + 7 }
    func rowWidth(_ item: PanelShortcut) -> CGFloat {
        let name: CGFloat = max(140, width(item.name, nameStyle))
        return 7 + name + 14 + 4 + 14 + badgeWidth(item.shortcut) + 7
    }
    let columnWidths: [CGFloat] = columns.map { column in
        column.flatMap(\.items).map(rowWidth).max() ?? 0
    }
    let titleStyle = Style.sized(12, .bold)
    func columnHeight(_ column: [(title: String, items: [PanelShortcut])]) -> CGFloat {
        column.map { titleStyle.lineHeight + 3 + CGFloat($0.items.count) * (7 + rowHeight) }.reduce(0, +) + CGFloat(column.count - 1) * 16
    }
    let columnsHeight = columns.map(columnHeight).max() ?? 0
    let footerStyle = Style.sized(12, .regular)
    let hudWidth = 24 + columnWidths.reduce(0, +) + 32 + 24
    let hudHeight = 24 + 36 + 20 + 1 + 20 + columnsHeight + 20 + footerStyle.lineHeight + 24
    let canvasWidth = hudWidth + 80, canvasHeight = hudHeight + 80

    let svg = SVG()
    svg.rect(0, 0, canvasWidth, canvasHeight, radius: 0, fill: "#e7eaf0")
    let left: CGFloat = 40, top: CGFloat = 40
    svg.rect(left, top, hudWidth, hudHeight, radius: 16, fill: "#000", opacity: 0.75, filter: "window-shadow")

    // Header: the app icon, name and title
    let headerY = top + 24 + 18
    svg.definitions.append(##"<linearGradient id="app-icon" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1580f0"/><stop offset="1" stop-color="#3aa0ff"/></linearGradient>"##)
    svg.rect(left + 24, headerY - 16, 32, 32, radius: 7, fill: "url(#app-icon)")
    svg.icon("waveform.badge.microphone", x: left + 24 + 6, centerY: headerY, size: 20, color: Color.white)
    let nameX = left + 24 + 32 + 10
    svg.text(strings.name("SpeechDock", in: view), x: nameX, centerY: headerY - 8, .sized(14, .semibold), color: "#fff")
    svg.text(strings.label("Keyboard Shortcuts", in: view), x: nameX, centerY: headerY + 9, .sized(12, .regular), color: "#fff", opacity: 0.7)
    let dividerY = top + 24 + 36 + 20
    svg.add(##"<path d="M\##(f(left + 24)) \##(f(dividerY + 0.5))h\##(f(hudWidth - 48))" stroke="#fff" stroke-opacity="0.2"/>"##)

    // The two columns
    var columnX = left + 24
    for (index, column) in columns.enumerated() {
        var y = dividerY + 1 + 20
        for section in column {
            svg.text(section.title, x: columnX, centerY: y + titleStyle.lineHeight / 2, titleStyle, color: "#fff", opacity: 0.7)
            y += titleStyle.lineHeight + 3
            for item in section.items {
                y += 7
                let cy = y + rowHeight / 2
                svg.text(item.name, x: columnX + 7, centerY: cy, nameStyle, color: "#fff", opacity: 0.9)
                let badge = badgeWidth(item.shortcut)
                let badgeX = columnX + columnWidths[index] - 7 - badge
                svg.rect(badgeX, cy - 10.5, badge, 21, radius: 4, fill: "#fff", opacity: 0.15)
                monospacedText(svg, item.shortcut, x: badgeX + 7, centerY: cy, size: 12, color: "#fff")
                y += rowHeight
            }
            y += 16
        }
        columnX += columnWidths[index] + 32
    }

    // Footer
    let footer = format(strings, key: "Press ESC or %@ to dismiss", shownAs: #"Text("Press ESC or \(dismissShortcutString) to dismiss")"#, in: view, defaultShortcut("shortcutHUDDefault"))
    let footerY = top + hudHeight - 24 - footerStyle.lineHeight / 2
    svg.text(footer, x: left + (hudWidth - width(footer, footerStyle)) / 2, centerY: footerY, footerStyle, color: "#fff", opacity: 0.5)

    return svg.document(width: canvasWidth, height: canvasHeight, title: strings.label("Keyboard Shortcuts", in: view))
}

/// The STT panel while an audio file is dragged over its text area.
func fileTranscription(_ strings: Strings) -> String {
    let view = "Views/FloatingWindow/TranscriptionFloatingView.swift"
    let svg = SVG()
    panelSurface(svg, height: panelHeight)
    sttHeader(svg, strings)

    // The text area, highlighted for the drop
    let left = margin + panelPad, areaWidth = panelWidth - panelPad * 2
    textArea(svg, top: panelAreaTop, height: panelAreaHeight, text: "", fontSize: 18)
    svg.rect(left, panelAreaTop, areaWidth, panelAreaHeight, radius: 8, fill: Color.accent, opacity: 0.1)
    svg.add(##"<rect x="\##(f(left + 1.5))" y="\##(f(panelAreaTop + 1.5))" width="\##(f(areaWidth - 3))" height="\##(f(panelAreaHeight - 3))" rx="8" fill="none" stroke="\##(Color.accent)" stroke-width="3"/>"##)
    let centerX = left + areaWidth / 2, centerY = panelAreaTop + panelAreaHeight / 2
    let prompt = strings.label("Drop audio file to transcribe", in: view)
    let promptStyle = Style.calloutMedium
    let blockHeight = 36 + 8 + promptStyle.lineHeight
    svg.icon("waveform.badge.magnifyingglass", x: centerX - 18, centerY: centerY - blockHeight / 2 + 18, size: 36, color: Color.accent)
    svg.text(prompt, x: centerX - width(prompt, promptStyle) / 2, centerY: centerY + blockHeight / 2 - promptStyle.lineHeight / 2, promptStyle, color: Color.accent)

    // The file being dragged, with the pointer
    let fileX = centerX + 150, fileY = centerY - 34
    svg.add(##"<path d="M\##(f(fileX)) \##(f(fileY))h34l14 14v50h-48z" fill="#fbfbfb" stroke="#b8b8bd" stroke-width="1"/><path d="M\##(f(fileX + 34)) \##(f(fileY))v14h14" fill="#e6e6ea" stroke="#b8b8bd" stroke-width="1"/>"##)
    svg.icon("waveform", x: fileX + 12, centerY: fileY + 38, size: 24, color: Color.secondary)
    let fileName = "interview.m4a"
    svg.text(fileName, x: fileX + 24 - width(fileName, .callout) / 2, centerY: fileY + 64 + 4 + Style.callout.lineHeight / 2, .callout, color: Color.label)
    svg.icon("pointer", x: fileX + 38, centerY: fileY + 46, size: 18, color: "#000")

    translationRow(svg, strings, centerY: panelTranslationY, target: languages(strings).target, button: .translate(enabled: false))
    targetGroup(svg, strings, centerY: panelActionY, selected: false, expanded: false, pasteEnabled: false)
    var end = margin + panelWidth - panelPad
    faded(svg, 0.4) {
        end = actionButton(svg, right: end, centerY: panelActionY, title: strings.label("Copy", in: view), icon: "doc.on.doc", prominent: false) - 8
        end = actionButton(svg, right: end, centerY: panelActionY, title: strings.label("Save Text", in: view), icon: "square.and.arrow.down", prominent: false) - 8
    }
    _ = actionButton(svg, right: end, centerY: panelActionY, title: strings.label("Record", in: view), icon: "mic.fill", prominent: true)

    return svg.document(width: panelWidth + margin * 2, height: panelHeight + margin * 2, title: prompt)
}

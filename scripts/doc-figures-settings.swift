// The Settings window's figures, drawn with the parts of generate-doc-figures.swift.
//
// Each page is described as data (sections of rows, as the page's Form lays
// them out) and drawn by one renderer for the window, its sidebar and the
// grouped form. A page longer than the window is cut where the window ends.

import AppKit

let settingsFigures: [Figure] = [
    ("settings-stt", settingsSTT),
    ("settings-tts", settingsTTS),
    ("settings-translation", settingsTranslation),
    ("settings-subtitle", settingsSubtitle),
    ("settings-shortcuts", settingsShortcuts),
    ("settings-text-replacement", settingsTextReplacement),
    ("settings-appearance", settingsAppearance),
    ("settings-apikeys", settingsAPIKeys),
]

/// Symbols these figures use besides the shared ones, on the same 16 × 16 grid.
let settingsIcons: [String: String] = [
    "keyboard": #"<rect x="1" y="3.5" width="14" height="9" rx="1.5" stroke="currentColor" stroke-width="1.2" fill="none"/><path d="M3.5 6h1M6 6h1M8.5 6h1M11 6h1.5M3.5 8.2h1M6 8.2h1M8.5 8.2h1M11 8.2h1.5M5 10.4h6" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/>"#,
    "text.badge.plus": #"<circle cx="4" cy="4" r="3" fill="currentColor"/><path d="M4 2.5v3M2.5 4h3" stroke="white" stroke-width="1" stroke-linecap="round"/><path d="M8.5 4h6M1.5 8.5h13M1.5 12.5h13" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>"#,
    "paintbrush": #"<path d="M14 2l-6.5 7.2 1.3 1.3L15 4z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" fill="none"/><path d="M6.6 10.1c-1.6-.4-3 .6-3.2 2.2-.1 1-.7 1.6-1.9 1.9 2.6.9 5.6.2 5.9-2.3z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" fill="none"/>"#,
    "key": #"<circle cx="8" cy="4.6" r="3.1" stroke="currentColor" stroke-width="1.3" fill="none"/><circle cx="8" cy="3.9" r=".9" fill="currentColor"/><path d="M8 7.7v6.8M8 11h2M8 13h1.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>"#,
    "info.circle": #"<circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.3" fill="none"/><circle cx="8" cy="5" r=".9" fill="currentColor"/><path d="M7 7.3h1.1v4.2M6.8 11.5h2.6" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" fill="none"/>"#,
    "chevron.up.down": #"<path d="M5 6.2L8 3.4l3 2.8M5 9.8L8 12.6l3-2.8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
    "eye": #"<path d="M1 8s2.6-4.5 7-4.5S15 8 15 8s-2.6 4.5-7 4.5S1 8 1 8z" stroke="currentColor" stroke-width="1.2" fill="none"/><circle cx="8" cy="8" r="2.2" stroke="currentColor" stroke-width="1.2" fill="none"/>"#,
    "minus.circle": #"<circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.3" fill="none"/><path d="M5 8h6" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>"#,
    "arrow.counterclockwise": #"<path d="M3.4 6.2A5 5 0 1 1 3 9.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" fill="none"/><path d="M2.6 2.8v3.6h3.6" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
    "arrow.right": #"<path d="M2 8h11M9 4l4 4-4 4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
]

// MARK: - Reading the app

let settingsDirectory = "Views/Settings"

/// The sidebar's categories in order: name key and symbol.
func settingsCategories() -> [(id: String, name: String, icon: String)] {
    let path = "\(settingsDirectory)/SettingsCategory.swift"
    let text = source(path)
    func pairs(_ pattern: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        var result: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            result[String(text[Range(match.range(at: 1), in: text)!])] = String(text[Range(match.range(at: 2), in: text)!])
        }
        return result
    }
    let names = pairs(#"case \.(\w+): return NSLocalizedString\("([^"]+)""#)
    let icons = pairs(#"case \.(\w+): return "([^"]+)""#)
    let order = try! NSRegularExpression(pattern: #"^    case (\w+)$"#, options: .anchorsMatchLines)
    return order.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
        let id = String(text[Range(match.range(at: 1), in: text)!])
        guard let name = names[id], let icon = icons[id] else { fail("\(path) has no name or icon for \(id)") }
        return (id, name, icon)
    }
}

/// A `static let name: Type = value` of a source file.
func staticValue(_ name: String, in path: String) -> String {
    let text = source(path)
    let regex = try! NSRegularExpression(pattern: #"static let \#(name): \w+ = ([^\s{]+)"#)
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { fail("\(path) has no \(name)") }
    return String(text[Range(match.range(at: 1), in: text)!])
}

func number(_ name: String, in path: String = "App/AppState.swift") -> Double {
    guard let value = Double(defaultValue(name, in: path)) else { fail("\(name) in \(path) is not a number") }
    return value
}

func flag(_ name: String, in path: String = "App/AppState.swift") -> Bool {
    defaultValue(name, in: path) == "true"
}

extension Strings {
    /// A label made from a number, as `Text("\(n) lines")` looks up "%lld lines";
    /// without a translation the English form is shown.
    func counted(_ key: String, _ value: Int, shownBy snippet: String, in view: String) -> String {
        guard source(view).contains(snippet) else { fail("\(view) no longer shows \(snippet)") }
        return (table[key] ?? key).replacingOccurrences(of: "%lld", with: String(value))
    }
}

extension Strings {
    /// A label whose source writes some characters as escapes, as `\u{2318}` for ⌘.
    func label(_ key: String, writtenAs written: String, in view: String) -> String {
        guard source(view).contains("\"\(written)\"") else { fail("\(view) no longer shows \"\(written)\"") }
        guard let value = table[key] else { fail("\(language).lproj has no \"\(key)\"") }
        return value
    }
}

/// The raw value of an enum case, as in `case openAI = "OpenAI"`.
func rawValue(_ name: String, in path: String) -> String {
    let text = source(path)
    guard let range = text.range(of: #"case \#(name) = "[^"]+""#, options: .regularExpression) else { fail("\(path) has no case \(name)") }
    return String(text[range].split(separator: "\"")[1])
}

/// The localization key a case's display name uses, as in
/// `case .floating: return NSLocalizedString("Floating", ...`.
func displayNameKey(_ name: String, in path: String) -> String {
    let text = source(path)
    guard let range = text.range(of: #"case \.\#(name): return NSLocalizedString\("[^"]+""#, options: .regularExpression) else { fail("\(path) has no display name for \(name)") }
    return String(text[range].split(separator: "\"")[1])
}

/// A panel shortcut's default, written as CustomShortcut.displayString writes it.
func panelShortcut(_ action: String) -> String {
    let path = "Models/KeyboardShortcutSettings.swift"
    let text = source(path)
    let caseRegex = try! NSRegularExpression(pattern: #"case \.\#(action):\s*(?://[^\n]*\s*)*return CustomShortcut\(([^\n]*)\)\n"#)
    guard let match = caseRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { fail("\(path) has no default for \(action)") }
    let arguments = String(text[Range(match.range(at: 1), in: text)!])
    let symbols = [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")]
        .filter { arguments.contains(".\($0.0)") }.map(\.1).joined()
    let key: String
    if let letter = arguments.range(of: #"key: "([^"]+)""#, options: .regularExpression) {
        key = String(arguments[letter]).dropFirst(6).dropLast().uppercased()
    } else if let code = arguments.range(of: #"kVK_\w+"#, options: .regularExpression) {
        let name = String(arguments[code])
        guard let mapped = text.range(of: #"case \#(name): return "([^"]+)""#, options: .regularExpression) else { fail("\(path) does not name \(name)") }
        key = String(text[mapped].split(separator: "\"")[1])
    } else {
        fail("\(path): cannot read the key of \(action)")
    }
    return symbols + key
}

// MARK: - The page as data

indirect enum SettingsRow {
    /// A row the view stacks under the row above it, without a separator.
    case joined(SettingsRow)
    /// A picker: its label, the shown value (with an optional symbol), and notes below.
    case picker(String, String, icon: String? = nil, notes: [String] = [])
    /// A label at the left and a picker of fixed width at the right.
    case labeledPicker(String, String, width: CGFloat)
    case note(String, color: String = Color.secondary)
    case heading(String)
    case toggle(String, detail: String? = nil, on: Bool)
    /// A slider: label, value text, position 0...1, end labels, a Reset link and a note.
    case slider(String, String, position: CGFloat, ends: (Style, String, Style, String)? = nil, reset: String? = nil, note: String? = nil)
    case button(String, alignRight: Bool)
    case hotkey(String, String)
    case panelShortcut(String, String)
    case keyField(placeholder: String, status: String, save: String)
}

struct SettingsSection {
    var header: String?
    var rows: [SettingsRow]
    var footer: String?
}

// MARK: - Drawing

let settingsWindowWidth: CGFloat = 820
let settingsWindowHeight: CGFloat = 640
let sidebarWidth: CGFloat = 210
let formInset: CGFloat = 20
let rowPad: CGFloat = 12
let groupFill = "#000"

/// The window, its sidebar with `selected` highlighted, and a clip for the page.
/// Returns the SVG and the left edge of the page.
func settingsWindow(_ strings: Strings, selected: String) -> SVG {
    let svg = SVG()
    let left = margin, top = margin
    svg.definitions.append("<clipPath id=\"settings-window\"><rect x=\"\(f(left))\" y=\"\(f(top))\" width=\"\(f(settingsWindowWidth))\" height=\"\(f(settingsWindowHeight))\" rx=\"12\"/></clipPath>")
    svg.rect(left, top, settingsWindowWidth, settingsWindowHeight, radius: 12, fill: "#fbfbfb", stroke: "#000", strokeOpacity: 0.12, filter: "window-shadow")
    svg.add("<g clip-path=\"url(#settings-window)\">")
    svg.rect(left, top, sidebarWidth, settingsWindowHeight, radius: 0, fill: "#ebebed")
    svg.add("<path d=\"M\(f(left + sidebarWidth + 0.5)) \(f(top))V\(f(top + settingsWindowHeight))\" stroke=\"black\" stroke-opacity=\"0.08\"/>")
    for (index, color) in ["#ff5f57", "#febc2e", "#28c840"].enumerated() {
        svg.add("<circle cx=\"\(f(left + 20 + CGFloat(index) * 20))\" cy=\"\(f(top + 20))\" r=\"6\" fill=\"\(color)\" stroke=\"black\" stroke-opacity=\"0.1\"/>")
    }
    var y = top + 52
    for category in settingsCategories() {
        let name = strings.label(category.name, in: "\(settingsDirectory)/SettingsCategory.swift")
        if category.id == selected {
            svg.rect(left + 10, y, sidebarWidth - 20, 30, radius: 6, fill: "#000", opacity: 0.08)
        }
        svg.icon(category.icon, x: left + 22, centerY: y + 15, size: 16, color: Color.accent)
        svg.text(name, x: left + 48, centerY: y + 15, .body, color: Color.label)
        y += 32
    }
    return svg
}

func finishSettings(_ svg: SVG, title: String) -> String {
    svg.add("</g>")
    return svg.document(width: settingsWindowWidth + margin * 2, height: settingsWindowHeight + margin * 2, title: title)
}

let formLeft = margin + sidebarWidth + formInset
let formWidth = settingsWindowWidth - sidebarWidth - formInset * 2
let rowWidth = formWidth - rowPad * 2

/// Wrapped lines of text no wider than the row.
func lines(_ text: String, _ style: Style, limit: CGFloat = rowWidth) -> [String] {
    wrap(text, style, limit: limit * 0.98)
}

func drawLines(_ svg: SVG, _ text: String, _ style: Style, x: CGFloat, top: CGFloat, color: String, limit: CGFloat = rowWidth) -> CGFloat {
    var y = top
    for line in lines(text, style, limit: limit) {
        svg.text(line, x: x, centerY: y + style.lineHeight / 2, style, color: color)
        y += style.lineHeight
    }
    return y - top
}

func linesHeight(_ text: String, _ style: Style, limit: CGFloat = rowWidth) -> CGFloat {
    CGFloat(lines(text, style, limit: limit).count) * style.lineHeight
}

/// A switch, its right edge at `right`.
func switchControl(_ svg: SVG, right: CGFloat, centerY: CGFloat, on: Bool, small: Bool = false) {
    let w: CGFloat = small ? 26 : 34, h: CGFloat = small ? 15 : 20
    let x = right - w
    svg.rect(x, centerY - h / 2, w, h, radius: h / 2, fill: on ? Color.accent : "#000", opacity: on ? 1 : 0.1)
    let knob = h / 2 - 1.5
    let cx = on ? x + w - h / 2 : x + h / 2
    svg.add("<circle cx=\"\(f(cx))\" cy=\"\(f(centerY))\" r=\"\(f(knob))\" fill=\"white\" filter=\"url(#control-shadow)\"/>")
}

/// A picker's value and its up/down button, ending at `right`.
func pickerValue(_ svg: SVG, right: CGFloat, centerY: CGFloat, value: String, icon: String? = nil) {
    svg.rect(right - 20, centerY - 10, 20, 20, radius: 5, fill: "#000", opacity: 0.06)
    svg.icon("chevron.up.down", x: right - 16, centerY: centerY, size: 12, color: Color.label)
    let w = svg.text(value, x: right - 20 - 8, centerY: centerY, .body, color: Color.label, anchorEnd: true)
    if let icon { svg.icon(icon, x: right - 20 - 8 - w - 6 - 14, centerY: centerY, size: 14, color: Color.label) }
}

/// A bordered push button with its title; returns its left edge.
func pushButton(_ svg: SVG, right: CGFloat, centerY: CGFloat, title: String, style: Style = .body, enabled: Bool = true, minWidth: CGFloat = 0) -> CGFloat {
    let w = max(minWidth, width(title, style) + 20)
    let x = right - w
    svg.rect(x, centerY - 11, w, 22, radius: 5, fill: Color.white, stroke: "#000", strokeOpacity: 0.12, filter: "control-shadow")
    svg.text(title, x: x + (w - width(title, style)) / 2, centerY: centerY, style, color: Color.label, opacity: enabled ? 1 : 0.35)
    return x
}

/// The height a row takes, and draws it when given an SVG.
func settingsRow(_ svg: SVG?, _ row: SettingsRow, top: CGFloat) -> CGFloat {
    let x = formLeft + rowPad, right = formLeft + formWidth - rowPad
    let body = Style.body.lineHeight, callout = Style.callout.lineHeight
    switch row {
    case let .joined(inner):
        return settingsRow(svg, inner, top: top - 8) - 8
    case let .picker(label, value, icon, notes):
        var height = 8 + max(body, 20)
        for note in notes { height += 4 + linesHeight(note, .callout) }
        if let svg {
            let y = top + 8 + max(body, 20) / 2
            svg.text(label, x: x, centerY: y, .body, color: Color.label)
            pickerValue(svg, right: right, centerY: y, value: value, icon: icon)
            var noteTop = top + 8 + max(body, 20) + 4
            for note in notes { noteTop += drawLines(svg, note, .callout, x: x, top: noteTop, color: Color.secondary) + 4 }
        }
        return height + 8
    case let .labeledPicker(label, value, pickerWidth):
        if let svg {
            let y = top + 8 + 10
            svg.text(label, x: x, centerY: y, .body, color: Color.label)
            svg.rect(right - pickerWidth, y - 10, pickerWidth, 20, radius: 5, fill: Color.white, stroke: "#000", strokeOpacity: 0.12, filter: "control-shadow")
            svg.text(value, x: right - pickerWidth + 8, centerY: y, .body, color: Color.label)
            svg.icon("chevron.up.down", x: right - 18, centerY: y, size: 12, color: Color.label)
        }
        return 8 + 20 + 8
    case let .note(text, color):
        if let svg { _ = drawLines(svg, text, .callout, x: x, top: top + 8, color: color) }
        return 8 + linesHeight(text, .callout) + 8
    case let .heading(text):
        if let svg { svg.text(text, x: x, centerY: top + 8 + body / 2, .headline, color: Color.label) }
        return 8 + body
    case let .toggle(label, detail, on):
        let textWidth = rowWidth - 50
        let height = body + (detail.map { 2 + linesHeight($0, .callout, limit: textWidth) } ?? 0)
        if let svg {
            svg.text(label, x: x, centerY: top + 8 + body / 2, .body, color: Color.label)
            if let detail { _ = drawLines(svg, detail, .callout, x: x, top: top + 8 + body + 2, color: Color.secondary, limit: textWidth) }
            switchControl(svg, right: right, centerY: top + 8 + height / 2, on: on)
        }
        return 8 + height + 8
    case let .slider(label, value, position, ends, reset, note):
        var height = 8 + body + 4 + 20
        if let note { height += 4 + linesHeight(note, .callout) }
        if let svg {
            let y = top + 8 + body / 2
            svg.text(label, x: x, centerY: y, .body, color: Color.label)
            svg.text(value, x: right, centerY: y, .callout, color: Color.secondary, anchorEnd: true)
            let trackY = top + 8 + body + 4 + 10
            var trackLeft = x, trackRight = right
            if let reset {
                trackRight -= svg.text(reset, x: right, centerY: trackY, .callout, color: Color.accent, anchorEnd: true) + 8
            }
            if let (minStyle, minText, maxStyle, maxText) = ends {
                trackLeft += svg.text(minText, x: x, centerY: trackY, minStyle, color: Color.secondary) + 8
                trackRight -= svg.text(maxText, x: trackRight, centerY: trackY, maxStyle, color: Color.secondary, anchorEnd: true) + 8
            }
            svg.rect(trackLeft, trackY - 2, trackRight - trackLeft, 4, radius: 2, fill: "#000", opacity: 0.1)
            let knobX = trackLeft + (trackRight - trackLeft) * position
            svg.rect(trackLeft, trackY - 2, knobX - trackLeft, 4, radius: 2, fill: Color.accent)
            svg.add("<circle cx=\"\(f(knobX))\" cy=\"\(f(trackY))\" r=\"9\" fill=\"white\" stroke=\"black\" stroke-opacity=\"0.12\" filter=\"url(#control-shadow)\"/>")
            if let note { _ = drawLines(svg, note, .callout, x: x, top: trackY + 10 + 4, color: Color.secondary) }
        }
        return height + 8
    case let .button(title, alignRight):
        if let svg {
            let y = top + 8 + 11
            if alignRight {
                _ = pushButton(svg, right: right, centerY: y, title: title, style: .callout)
            } else {
                let w = width(title, .body) + 20
                _ = pushButton(svg, right: x + w, centerY: y, title: title)
            }
        }
        return 8 + 22 + 8
    case let .hotkey(label, shortcut):
        if let svg {
            let y = top + 8 + 11
            svg.text(label, x: x, centerY: y, .body, color: Color.label)
            _ = pushButton(svg, right: right, centerY: y, title: shortcut, minWidth: 140)
        }
        return 8 + 22 + 8
    case let .panelShortcut(label, shortcut):
        if let svg {
            let y = top + 8 + 12
            svg.text(label, x: x, centerY: y, .body, color: Color.label)
            svg.icon("arrow.counterclockwise", x: right - 14, centerY: y, size: 14, color: Color.secondary)
            let boxRight = right - 14 - 8
            svg.rect(boxRight - 120, y - 12, 120, 24, radius: 6, fill: "#000", opacity: 0.05)
            let mono = Style.body
            svg.add("<text x=\"\(f(boxRight - 60))\" y=\"\(f(y + (mono.font.ascender + mono.font.descender) / 2))\" font-size=\"13\" text-anchor=\"middle\" font-family=\"ui-monospace, SFMono-Regular, Menlo, monospace\" fill=\"\(Color.label)\">\(xml(shortcut))</text>")
        }
        return 8 + 24 + 8
    case let .keyField(placeholder, status, save):
        if let svg {
            let y = top + 8 + 11
            svg.rect(x, y - 11, rowWidth - 26, 22, radius: 5, fill: Color.white, stroke: "#000", strokeOpacity: 0.15)
            svg.text(placeholder, x: x + 7, centerY: y, .body, color: Color.secondary, opacity: 0.7)
            svg.icon("eye", x: right - 16, centerY: y, size: 16, color: Color.accent)
            let statusY = y + 11 + 8 + callout / 2
            svg.icon("minus.circle", x: x, centerY: statusY, size: 13, color: Color.secondary)
            svg.text(status, x: x + 13 + 5, centerY: statusY, .callout, color: Color.secondary)
            _ = pushButton(svg, right: right, centerY: statusY + callout / 2 + 8 + 11, title: save, enabled: false)
        }
        return 8 + 22 + 8 + callout + 8 + 22 + 8
    }
}

/// Draws the sections of a grouped form from the top of the page.
func settingsForm(_ svg: SVG, _ sections: [SettingsSection], top: CGFloat = margin + 24) {
    var y = top
    for section in sections {
        if let header = section.header {
            y += 8
            svg.text(header, x: formLeft + rowPad, centerY: y + Style.headline.lineHeight / 2, .headline, color: Color.label)
            y += Style.headline.lineHeight + 8
        }
        let heights = section.rows.map { settingsRow(nil, $0, top: 0) }
        svg.rect(formLeft, y, formWidth, heights.reduce(0, +), radius: 10, fill: groupFill, opacity: 0.035)
        var rowTop = y
        for (index, row) in section.rows.enumerated() {
            if index > 0, !isContinuation(row) {
                svg.add("<path d=\"M\(f(formLeft + rowPad)) \(f(rowTop + 0.5))H\(f(formLeft + formWidth - rowPad))\" stroke=\"black\" stroke-opacity=\"0.08\"/>")
            }
            rowTop += settingsRow(svg, row, top: rowTop)
        }
        y = rowTop
        if let footer = section.footer {
            y += 6
            y += drawLines(svg, footer, .callout, x: formLeft + rowPad, top: y, color: Color.secondary)
        }
        y += 14
    }
}

/// Rows that belong to the row above them, as the views stack them without a separator.
func isContinuation(_ row: SettingsRow) -> Bool {
    if case .joined = row { return true }
    return false
}

// MARK: - Pages

let sttSettingsView = "\(settingsDirectory)/STTSettingsView.swift"
let ttsSettingsView = "\(settingsDirectory)/TTSSettingsView.swift"

func settingsSTT(_ strings: Strings) -> String {
    let view = sttSettingsView
    let svg = settingsWindow(strings, selected: "speechToText")
    let sources = "Models/AudioInputSource.swift"
    settingsForm(svg, [
        SettingsSection(header: strings.label("Provider & Model", in: view), rows: [
            .picker(strings.label("Provider", in: view), caseValue("macOS", in: "Services/RealtimeSTT/RealtimeSTTProtocol.swift")),
            .note(strings.label("Apple Speech (offline, realtime, no time limit)", in: "Services/RealtimeSTT/RealtimeSTTProtocol.swift")),
            .note(strings.label("Set API keys in the API Keys section to enable more providers", in: view), color: "#e07800"),
            .picker(strings.label("Model", in: view), strings.name("Apple Speech", in: "Services/RealtimeSTT/SpeechAnalyzerSTT.swift"),
                    notes: [strings.label("On-device speech recognition (macOS 26+)", in: "Services/RealtimeSTT/SpeechAnalyzerSTT.swift")]),
            .picker(strings.label("Language", in: view), languages(strings).spoken,
                    notes: [strings.label("Select the language you will speak. macOS recognition uses this language.", in: view)]),
        ]),
        SettingsSection(header: strings.label("Audio Input", in: view), rows: [
            .picker(strings.label("Audio Source", in: view), strings.label("Microphone", in: sources), icon: "mic.fill",
                    notes: [strings.label("Record from microphone", in: sources),
                            strings.label("App-specific audio capture is available in the menu bar and STT panel.", in: view)]),
            .picker(strings.label("Microphone", in: view), strings.label("System Default", in: "Services/AudioInputManager.swift"),
                    notes: [strings.label("Select the microphone device for speech recognition.", in: view)]),
        ]),
        SettingsSection(header: strings.label("Recording & Panel", in: view), rows: [
            .heading(strings.label("Panel Behavior", in: view)),
            .joined(.toggle(strings.label("Auto-start recording", in: view),
                    detail: strings.label("When enabled, recording starts automatically when the STT panel opens.", in: view), on: flag("sttAutoStart"))),
            .joined(.toggle(strings.label("Close panel after paste", in: view),
                    detail: strings.label("When enabled, the STT panel closes automatically after pasting text.", in: view), on: flag("closePanelAfterPaste"))),
        ]),
    ])
    return finishSettings(svg, title: strings.label("Speech-to-Text", in: "\(settingsDirectory)/SettingsCategory.swift"))
}

func settingsTTS(_ strings: Strings) -> String {
    let view = ttsSettingsView
    let svg = settingsWindow(strings, selected: "textToSpeech")
    let speed = number("selectedTTSSpeed")
    settingsForm(svg, [
        SettingsSection(header: strings.label("Provider & Voice", in: view), rows: [
            .picker(strings.label("Provider", in: view), caseValue("macOS", in: "Services/TTS/TTSProtocol.swift")),
            .note(strings.label("Local (offline, fast)", in: "Services/TTS/TTSProtocol.swift")),
            .note(strings.label("Set API keys in the API Keys section to enable more providers", in: view), color: "#e07800"),
            .picker(strings.label("Model", in: view), strings.label("System Default", in: "Services/TTS/MacOSTTS.swift"),
                    notes: [strings.label("macOS built-in TTS", in: "Services/TTS/MacOSTTS.swift")]),
            .picker(strings.label("Voice", in: view), strings.label("Auto (detect language)", in: "Services/TTS/MacOSTTS.swift")),
        ]),
        SettingsSection(header: strings.label("Playback", in: view), rows: [
            .slider(strings.label("Speed", in: view), String(format: "%.1fx", speed), position: CGFloat((speed - 0.5) / 1.5),
                    ends: (.callout, strings.label("Slow", in: view), .callout, strings.label("Fast", in: view)),
                    reset: strings.label("Reset", in: view)),
        ]),
        SettingsSection(header: strings.label("Language & Output", in: view), rows: [
            .picker(strings.label("Audio Output", in: view), strings.label("System Default", in: "Services/AudioOutputManager.swift"),
                    notes: [strings.label("Select the audio output device for speech playback.", in: view)]),
        ]),
        SettingsSection(header: strings.label("Panel Behavior", in: view), rows: [
            .toggle(strings.label("Auto-speak on panel open", in: view),
                    detail: strings.label("When enabled, TTS starts speaking automatically when the panel opens with text.", in: view), on: flag("ttsAutoSpeak")),
        ]),
    ])
    return finishSettings(svg, title: strings.label("Text-to-Speech", in: "\(settingsDirectory)/SettingsCategory.swift"))
}

func settingsTranslation(_ strings: Strings) -> String {
    let view = "\(settingsDirectory)/TranslationSettingsView.swift"
    let provider = "Models/TranslationProvider.swift"
    let svg = settingsWindow(strings, selected: "translation")
    settingsForm(svg, [
        SettingsSection(header: strings.label("Translation", in: view), rows: [
            .note(strings.label("The provider and target language apply to both the panel Translate button and subtitle translation. The model applies to the panel; subtitles use the provider's default model for speed.", in: view)),
            .picker(strings.label("Provider", in: view), caseValue("macOS", in: provider)),
            .note(strings.label("On-device, ~18 languages", in: provider)),
            .labeledPicker(strings.label("Target Language", in: view), languages(strings).target, width: 150),
            .note(strings.label("Only languages with installed language packs are shown. Install more in System Settings > General > Language & Region > Translation Languages.", in: view)),
        ]),
        SettingsSection(header: strings.label("Subtitle Translation", in: view), rows: [
            .note(strings.label("Real-time translation for subtitle mode (STT). Active only when subtitle mode is enabled.", in: view)),
            .toggle(strings.label("Enable Real-Time Translation", in: view),
                    detail: strings.label("Translate subtitles to target language in real-time.", in: view), on: flag("subtitleTranslationEnabled")),
            .joined(.toggle(strings.label("Show Original Text", in: view),
                    detail: strings.label("Display original text above the translation.", in: view), on: flag("subtitleShowOriginal"))),
        ]),
    ])
    return finishSettings(svg, title: strings.label("Translation", in: "\(settingsDirectory)/SettingsCategory.swift"))
}

func settingsSubtitle(_ strings: Strings) -> String {
    let view = "\(settingsDirectory)/SubtitleSettingsView.swift"
    let svg = settingsWindow(strings, selected: "subtitle")
    let fontSize = number("subtitleFontSize"), opacity = number("subtitleOpacity"), background = number("subtitleBackgroundOpacity")
    let maxLines = Int(defaultValue("subtitleMaxLines", in: "App/AppState.swift"))!
    let positions = "Models/SubtitlePosition.swift"
    let position = displayNameKey(String(defaultValue("subtitlePosition", in: "App/AppState.swift").dropFirst()), in: positions)
    settingsForm(svg, [
        SettingsSection(header: strings.label("Subtitle Mode", in: view), rows: [
            .toggle(strings.label("Enable Subtitle Mode", in: view),
                    detail: strings.label("Display real-time transcription as subtitles during recording.", in: view), on: flag("subtitleModeEnabled")),
        ]),
        SettingsSection(header: strings.label("Appearance", in: view), rows: [
            .picker(strings.label("Position", in: view), strings.label(position, in: positions)),
            .slider(strings.label("Font Size", in: view), strings.counted("%lld pt", Int(fontSize), shownBy: #"\(Int(appState.subtitleFontSize)) pt"#, in: view),
                    position: CGFloat((fontSize - 18) / 30), ends: (.sized(12, .regular), "A", .sized(20, .regular), "A"), reset: strings.label("Reset", in: view)),
            .slider(strings.label("Text Opacity", in: view), "\(Int(opacity * 100))%", position: CGFloat((opacity - 0.3) / 0.7)),
            .slider(strings.label("Background Opacity", in: view), "\(Int(background * 100))%", position: CGFloat((background - 0.1) / 0.8)),
            .picker(strings.label("Max Lines", in: view), strings.counted("%lld lines", maxLines, shownBy: #"\(lines) lines"#, in: view)),
            .toggle(strings.label("Hide STT Panel when active", in: view),
                    detail: strings.label("Temporarily hide the STT panel when subtitle mode is active.", in: view), on: flag("subtitleHidePanelWhenActive")),
        ]),
        SettingsSection(header: nil, rows: [.button(strings.label("Reset to Defaults", in: view), alignRight: true)]),
    ])
    return finishSettings(svg, title: strings.label("Subtitle", in: "\(settingsDirectory)/SettingsCategory.swift"))
}

func settingsShortcuts(_ strings: Strings) -> String {
    let view = "\(settingsDirectory)/ShortcutSettingsView.swift"
    let actions = "Models/KeyboardShortcutSettings.swift"
    let svg = settingsWindow(strings, selected: "shortcuts")
    let hotkeys: [(String, String)] = [
        ("Toggle STT Panel", "sttDefault"), ("Toggle TTS Panel", "ttsDefault"), ("OCR Region to TTS", "ocrDefault"),
        ("Toggle Subtitle Mode", "subtitleDefault"), ("Show Shortcuts", "shortcutHUDDefault"), ("Quick Transcription", "quickTranscriptionDefault"),
    ]
    let sttActions: [(String, String)] = [
        ("Record", "sttRecord"), ("Stop Recording", "sttStop"), ("Paste", "sttPaste"),
        ("Save Text", "sttSave"), ("Select Target", "sttTargetSelect"), ("Cancel", "sttCancel"),
    ]
    settingsForm(svg, [
        SettingsSection(header: strings.label("Global Hotkeys", in: view),
                        rows: hotkeys.map { .hotkey(strings.label($0.0, in: view), defaultShortcut($0.1)) },
                        footer: strings.label("Click on a shortcut and press a new key combination to change it. Shortcuts must include at least one modifier key (⌘, ⌥, ⌃, or ⇧).",
                                              writtenAs: #"Click on a shortcut and press a new key combination to change it. Shortcuts must include at least one modifier key (\u{2318}, \u{2325}, \u{2303}, or \u{21E7})."#, in: view)),
        SettingsSection(header: strings.label("STT Panel Shortcuts", in: view),
                        rows: sttActions.map { .panelShortcut(strings.label($0.0, in: actions), panelShortcut($0.1)) },
                        footer: strings.label("Shortcuts available when the STT transcription panel is open.", in: view)),
    ])
    return finishSettings(svg, title: strings.label("Shortcuts", in: "\(settingsDirectory)/SettingsCategory.swift"))
}

func settingsTextReplacement(_ strings: Strings) -> String {
    let view = "\(settingsDirectory)/TextReplacementSettingsView.swift"
    let service = "Services/TextReplacementService.swift"
    let svg = settingsWindow(strings, selected: "textReplacement")
    let left = margin + sidebarWidth + 16, right = margin + settingsWindowWidth - 16
    var y = margin + 24

    svg.text(strings.label("Built-in Patterns", in: view), x: left, centerY: y + Style.headline.lineHeight / 2, .headline, color: Color.label)
    y += Style.headline.lineHeight + 8
    y += drawLines(svg, strings.label("Automatically replace common patterns like URLs and emails.", in: view), .callout, x: left, top: y, color: Color.secondary, limit: right - left) + 8
    let patterns: [(String, String)] = [("URLs", "url"), ("Email Addresses", "email"), ("File Paths", "filePath")]
    let rowHeight: CGFloat = 32
    svg.rect(left, y, right - left, 8 + CGFloat(patterns.count) * rowHeight + 8, radius: 8, fill: Color.white, stroke: "#000", strokeOpacity: 0.06)
    var rowY = y + 8 + rowHeight / 2
    let replacementPattern = try! NSRegularExpression(pattern: #"case \.(\w+): return "( [^"]+ )""#)
    let serviceText = source(service)
    var replacements: [String: String] = [:]
    for match in replacementPattern.matches(in: serviceText, range: NSRange(serviceText.startIndex..., in: serviceText)) {
        replacements[String(serviceText[Range(match.range(at: 1), in: serviceText)!])] = String(serviceText[Range(match.range(at: 2), in: serviceText)!])
    }
    for (name, id) in patterns {
        var x = left + 8
        switchControl(svg, right: x + 26, centerY: rowY, on: false, small: true)
        x += 26 + 8
        svg.text(strings.label(name, in: service), x: x, centerY: rowY, .body, color: Color.label)
        x += 120 + 8
        svg.icon("arrow.right", x: x, centerY: rowY, size: 12, color: Color.secondary)
        x += 12 + 8
        let fieldRight = right - 8 - 16 - 8
        svg.rect(x, rowY - 11, fieldRight - x, 22, radius: 5, fill: Color.white, stroke: "#000", strokeOpacity: 0.15)
        guard let replacement = replacements[id] else { fail("\(service) has no replacement for \(id)") }
        svg.add("<text x=\"\(f(x + 7))\" y=\"\(f(rowY + (Style.body.font.ascender + Style.body.font.descender) / 2))\" font-size=\"13\" fill=\"\(Color.label)\" xml:space=\"preserve\">\(xml(replacement))</text>")
        svg.icon("arrow.counterclockwise", x: right - 8 - 16, centerY: rowY, size: 14, color: Color.secondary)
        rowY += rowHeight
    }
    y += 8 + CGFloat(patterns.count) * rowHeight + 8 + 16
    svg.add("<path d=\"M\(f(left)) \(f(y + 0.5))H\(f(right))\" stroke=\"black\" stroke-opacity=\"0.1\"/>")
    y += 16

    svg.text(strings.label("Custom Rules", in: view), x: left, centerY: y + Style.headline.lineHeight / 2, .headline, color: Color.label)
    svg.text(strings.counted("%lld rules", 0, shownBy: #"\(service.rules.count) rules"#, in: view), x: right, centerY: y + Style.headline.lineHeight / 2, .callout, color: Color.secondary, anchorEnd: true)
    y += Style.headline.lineHeight + 8
    let emptyHeight: CGFloat = 20 + 24 + 8 + Style.callout.lineHeight + 8 + Style.callout.lineHeight + 20
    svg.rect(left, y, right - left, emptyHeight, radius: 8, fill: Color.white, stroke: "#000", strokeOpacity: 0.06)
    let center = (left + right) / 2
    svg.icon("text.badge.plus", x: center - 12, centerY: y + 20 + 12, size: 24, color: Color.secondary)
    var textY = y + 20 + 24 + 8 + Style.callout.lineHeight / 2
    for key in ["No custom rules", "Add rules for specific text replacements."] {
        let text = strings.label(key, in: view)
        svg.text(text, x: center - width(text, .callout) / 2, centerY: textY, .callout, color: Color.secondary)
        textY += Style.callout.lineHeight + 8
    }
    y += emptyHeight + 8 + 11
    let add = strings.label("Add", in: view)
    let addWidth = 10 + 12 + 4 + width(add, .body) + 10
    svg.rect(left, y - 11, addWidth, 22, radius: 5, fill: Color.white, stroke: "#000", strokeOpacity: 0.12, filter: "control-shadow")
    svg.icon("plus", x: left + 10, centerY: y, size: 12, color: Color.label)
    svg.text(add, x: left + 10 + 12 + 4, centerY: y, .body, color: Color.label)
    let export = pushButton(svg, right: right, centerY: y, title: strings.label("Export...", in: view), enabled: false)
    _ = pushButton(svg, right: export - 8, centerY: y, title: strings.label("Import...", in: view))
    return finishSettings(svg, title: strings.label("Text Replacement", in: "\(settingsDirectory)/SettingsCategory.swift"))
}

func settingsAppearance(_ strings: Strings) -> String {
    let view = "\(settingsDirectory)/AppearanceSettingsView.swift"
    let svg = settingsWindow(strings, selected: "appearance")
    let size = number("panelTextFontSize")
    let low = Double(staticValue("minPanelTextFontSize", in: "App/AppState.swift"))!
    let high = Double(staticValue("maxPanelTextFontSize", in: "App/AppState.swift"))!
    let styleName = displayNameKey(String(defaultValue("panelStyle", in: "App/AppState.swift").dropFirst()), in: "App/AppState.swift")
    settingsForm(svg, [
        SettingsSection(header: strings.label("Panel Appearance", in: view), rows: [
            .slider(strings.label("Text Font Size", in: view), strings.counted("%lld pt", Int(size), shownBy: #"\(Int(appState.panelTextFontSize)) pt"#, in: view),
                    position: CGFloat((size - low) / (high - low)), ends: (.sized(12, .regular), "A", .sized(16, .regular), "A"),
                    reset: strings.label("Reset", in: view), note: strings.label("Font size for text in STT and TTS panels.", in: view)),
            .picker(strings.label("Panel Style", in: view), strings.label(styleName, in: "App/AppState.swift")),
            .note(strings.label("Floating: Always-on-top borderless panels. Standard Window: Regular windows with title bar. Only one panel (STT or TTS) can be open at a time.", in: view)),
        ]),
        SettingsSection(header: strings.label("Startup", in: view), rows: [
            .toggle(strings.label("Launch at Login", in: view),
                    detail: strings.label("SpeechDock will start automatically when you log in", in: view), on: false),
        ]),
    ])
    return finishSettings(svg, title: strings.label("Appearance", in: "\(settingsDirectory)/SettingsCategory.swift"))
}

func settingsAPIKeys(_ strings: Strings) -> String {
    let view = "\(settingsDirectory)/APISettingsView.swift"
    let providers = "Models/STTProvider.swift"
    let svg = settingsWindow(strings, selected: "apiKeys")
    let footerRegex = try! NSRegularExpression(pattern: #"case \.(\w+):\s*return NSLocalizedString\("([^"]+)", comment: "API key footer"\)"#)
    let providerText = source(providers)
    var footers: [String: String] = [:]
    for match in footerRegex.matches(in: providerText, range: NSRange(providerText.startIndex..., in: providerText)) {
        footers[String(providerText[Range(match.range(at: 1), in: providerText)!])] = String(providerText[Range(match.range(at: 2), in: providerText)!])
    }
    let keySections: [SettingsSection] = ["openAI", "gemini", "elevenLabs", "grok"].map { id in
        guard let footer = footers[id] else { fail("\(providers) has no footer for \(id)") }
        return SettingsSection(header: rawValue(id, in: providers),
                               rows: [.keyField(placeholder: strings.label("API Key", in: view),
                                                status: strings.label("Not Set", in: view),
                                                save: strings.label("Save to Keychain", in: view))],
                               footer: strings.label(footer, in: providers))
    }
    settingsForm(svg, [
        SettingsSection(header: strings.label("About API Keys", in: view), rows: [
            .note(strings.label("SpeechDock works without API keys using macOS built-in STT/TTS. Cloud providers below are optional and offer additional voices, models, and languages.", in: view)),
            .note(strings.label("Each field takes the key itself or a 1Password reference (op://vault/item/field). A reference is read with the 1Password CLI (op) when Settings opens or a key is first needed; only the reference is stored in the keychain.", in: view)),
        ]),
    ] + keySections)
    return finishSettings(svg, title: strings.label("API Keys", in: "\(settingsDirectory)/SettingsCategory.swift"))
}

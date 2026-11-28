// Draws the schematic figures of the documentation: docs/images/<name>.svg for
// the English pages and docs/images/ja/<name>.svg for the Japanese ones.
// This file has the shared parts and the panels; doc-figures-settings.swift
// draws the Settings window and doc-figures-tools.swift the smaller tools.
//
// A figure's layout is written here. What it shows is read from the app:
// - a label's text from Resources/<language>.lproj/Localizable.strings, and the
//   label must still appear in the view that shows it, so a control that is
//   renamed or removed stops this script;
// - language and provider names from the models that define them;
// - text widths from the system font the panels use;
// - counts from the app's own code (Utilities/TextStatistics.swift), compiled
//   with this file.
//
// Run from the repository root:
//
//     rake docs:figures
//
// Edit this file, not the generated SVGs.

import AppKit

// MARK: - Reading the app

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-doc-figures: \(message)\n".utf8))
    exit(1)
}

func source(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    return text
}

func unescape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
}

/// The key/value pairs of a Localizable.strings file.
func localizedStrings(_ language: String) -> [String: String] {
    let pattern = try! NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";"#, options: .anchorsMatchLines)
    let text = source("Resources/\(language).lproj/Localizable.strings")
    var table: [String: String] = [:]
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let key = String(text[Range(match.range(at: 1), in: text)!])
        let value = String(text[Range(match.range(at: 2), in: text)!])
        table[unescape(key)] = unescape(value)
    }
    return table
}

/// The value a Swift source assigns to a case, as in `case .english: return "English"`
/// or `case macOS = "macOS"`.
func caseValue(_ name: String, in path: String) -> String {
    let text = source(path)
    for pattern in [#"case \.\#(name): return "([^"]+)""#, #"case \#(name) = "([^"]+)""#] {
        let regex = try! NSRegularExpression(pattern: pattern)
        if let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            return String(text[Range(match.range(at: 1), in: text)!])
        }
    }
    fail("\(path) has no case \(name)")
}

struct Strings {
    let language: String
    let table: [String: String]

    /// The text of a label that `view` shows, in this figure's language.
    func label(_ key: String, in view: String) -> String {
        guard source(view).contains("\"\(key)\"") else { fail("\(view) no longer shows \"\(key)\"") }
        guard let value = table[key] else { fail("\(language).lproj has no \"\(key)\"") }
        return value
    }

    /// A name `view` shows as it is, untranslated.
    func name(_ text: String, in view: String) -> String {
        guard source(view).contains("\"\(text)\"") else { fail("\(view) no longer shows \"\(text)\"") }
        return text
    }
}

// MARK: - Measuring text

enum Style {
    case body, bodyMedium, callout, calloutMedium, headline, text(CGFloat), sized(CGFloat, NSFont.Weight)

    var font: NSFont {
        switch self {
        case .body: return .systemFont(ofSize: 13)
        case .bodyMedium: return .systemFont(ofSize: 13, weight: .medium)
        case .callout: return .systemFont(ofSize: 12)
        case .calloutMedium: return .systemFont(ofSize: 12, weight: .medium)
        case .headline: return .systemFont(ofSize: 13, weight: .bold)
        case .text(let size): return .systemFont(ofSize: size)
        case .sized(let size, let weight): return .systemFont(ofSize: size, weight: weight)
        }
    }

    var weight: Int {
        switch self {
        case .bodyMedium, .calloutMedium: return 500
        case .headline: return 700
        case .sized(_, let weight):
            switch weight {
            case .medium: return 500
            case .semibold: return 600
            case .bold: return 700
            default: return 400
            }
        default: return 400
        }
    }

    var lineHeight: CGFloat {
        let font = self.font
        return ceil(font.ascender - font.descender + font.leading)
    }
}

/// The font a browser draws the figure's text with: the system font, and for
/// Japanese the Hiragino Sans weight a browser picks (AppKit's own fallback
/// is a narrower interface face that browsers do not use).
func measuringFont(_ style: Style) -> NSFont {
    let font = style.font
    let hiragino = style.weight >= 600 ? "HiraginoSans-W6" : style.weight >= 500 ? "HiraginoSans-W4" : "HiraginoSans-W3"
    let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [NSFontDescriptor(name: hiragino, size: font.pointSize)]])
    return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
}

func width(_ text: String, _ style: Style) -> CGFloat {
    ceil(NSAttributedString(string: text, attributes: [.font: measuringFont(style)]).size().width)
}

/// Splits text into lines no wider than `limit`: between words of Latin text,
/// and between any two characters of text written without spaces.
func wrap(_ text: String, _ style: Style, limit: CGFloat) -> [String] {
    var units: [String] = []
    for character in text {
        if character.isASCII, character != " ", let last = units.last, let previous = last.last, previous.isASCII, previous != " " {
            units[units.count - 1].append(character)
        } else {
            units.append(String(character))
        }
    }
    var lines: [String] = []
    var line = ""
    for unit in units {
        if !line.isEmpty && width(line + unit, style) > limit {
            lines.append(line)
            line = unit.hasPrefix(" ") ? String(unit.dropFirst()) : unit
        } else {
            line += unit
        }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

// MARK: - Drawing

enum Color {
    static let window = "#ececec"
    static let textArea = lightColor(in: "Views/FloatingWindow/TTSFloatingView.swift", after: "editableBackgroundColor")
    static let label = "#1d1d1f"
    static let secondary = "#7a7a7e"
    static let accent = "#007aff"
    static let purple = "#af52de"
    static let blue = "#007aff"
    static let gray = "#8e8e93"
    static let white = "#ffffff"
}

/// The light-mode colour a view defines after `marker`, as the first
/// `NSColor(red:green:blue:alpha: 1.0)` following the "Light mode" comment.
func lightColor(in path: String, after marker: String) -> String {
    let text = source(path)
    guard let start = text.range(of: marker), let light = text.range(of: "Light mode", range: start.upperBound..<text.endIndex) else { fail("\(path) has no light colour for \(marker)") }
    let regex = try! NSRegularExpression(pattern: #"NSColor\(red: ([0-9.]+), green: ([0-9.]+), blue: ([0-9.]+), alpha: 1\.0\)"#)
    guard let match = regex.firstMatch(in: text, range: NSRange(light.upperBound..<text.endIndex, in: text)) else { fail("\(path) has no light colour for \(marker)") }
    let components = (1...3).map { Double(text[Range(match.range(at: $0), in: text)!])! }
    return "#" + components.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
}

func f(_ v: CGFloat) -> String {
    let rounded = (v * 10).rounded() / 10
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(Double(rounded))
}

func xml(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

/// The symbols, drawn on a 16 × 16 grid. They stand for the system symbols the
/// panels use; they are drawn here rather than copied.
let baseIcons: [String: String] = [
    "xmark.circle.fill": #"<circle cx="8" cy="8" r="7" fill="currentColor"/><path d="M5.5 5.5l5 5m0-5l-5 5" stroke="white" stroke-width="1.6" stroke-linecap="round"/>"#,
    "waveform": #"<path d="M2 6v4M5 3.5v9M8 1.5v13M11 3.5v9M14 6v4" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>"#,
    "mic.fill": #"<rect x="5.5" y="1" width="5" height="8.5" rx="2.5" fill="currentColor"/><path d="M3.5 7.5a4.5 4.5 0 0 0 9 0M8 12v3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" fill="none"/>"#,
    "chevron.down": #"<path d="M4 6l4 4 4-4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
    "minus": #"<path d="M3 8h10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>"#,
    "plus": #"<path d="M3 8h10M8 3v10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>"#,
    "checkmark.circle": #"<circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.3" fill="none"/><path d="M5.2 8.2l2 2 3.6-4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
    "eraser": #"<g transform="rotate(-45 8 8)"><rect x="1.5" y="5" width="13" height="6" rx="1.5" stroke="currentColor" stroke-width="1.3" fill="none"/><path d="M6.5 5v6" stroke="currentColor" stroke-width="1.3"/></g>"#,
    "macwindow": #"<rect x="1.5" y="2.5" width="13" height="11" rx="2" stroke="currentColor" stroke-width="1.3" fill="none"/><path d="M1.5 5.5h13" stroke="currentColor" stroke-width="1.3"/>"#,
    "doc.on.clipboard": #"<rect x="3" y="2.5" width="10" height="12" rx="1.5" stroke="currentColor" stroke-width="1.3" fill="none"/><rect x="5.5" y="1" width="5" height="3" rx="1" fill="currentColor"/>"#,
    "square.and.arrow.down": #"<path d="M5 5.5H3.5v9h9v-9H11M8 1.5V10M5.5 7.5L8 10l2.5-2.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
    "doc.on.doc": #"<rect x="5" y="4" width="9" height="11" rx="1.5" stroke="currentColor" stroke-width="1.3" fill="none"/><path d="M3 12V2.8A1.3 1.3 0 0 1 4.3 1.5H10" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" fill="none"/>"#,
    "speaker.wave.2": #"<path d="M1.8 6h2.6L8 3v10L4.4 10H1.8z" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" fill="none"/><path d="M10.5 5.6a3.4 3.4 0 0 1 0 4.8M12.6 3.6a6.2 6.2 0 0 1 0 8.8" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" fill="none"/>"#,
    "speaker.wave.2.fill": #"<path d="M1.8 6h2.6L8 3v10L4.4 10H1.8z" fill="currentColor"/><path d="M10.5 5.6a3.4 3.4 0 0 1 0 4.8M12.6 3.6a6.2 6.2 0 0 1 0 8.8" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" fill="none"/>"#,
    "text.viewfinder": #"<path d="M1.5 5V2.8A1.3 1.3 0 0 1 2.8 1.5H5M11 1.5h2.2a1.3 1.3 0 0 1 1.3 1.3V5M14.5 11v2.2a1.3 1.3 0 0 1-1.3 1.3H11M5 14.5H2.8a1.3 1.3 0 0 1-1.3-1.3V11M4.5 5.5h7M4.5 8h7M4.5 10.5h4.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" fill="none"/>"#,
    "record.circle": #"<circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.3" fill="none"/><circle cx="8" cy="8" r="3.5" fill="currentColor"/>"#,
    "captions.bubble": #"<path d="M3 2h10a1.5 1.5 0 0 1 1.5 1.5v6.5A1.5 1.5 0 0 1 13 11.5H7l-3 3v-3H3A1.5 1.5 0 0 1 1.5 10V3.5A1.5 1.5 0 0 1 3 2z" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" fill="none"/><path d="M4.5 6h3M9 6h2.5M4.5 8.5h5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>"#,
    "mic.circle": #"<circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.3" fill="none"/><rect x="6.6" y="4" width="2.8" height="5" rx="1.4" fill="currentColor"/><path d="M5.3 7.8a2.7 2.7 0 0 0 5.4 0M8 10.5v1.5" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" fill="none"/>"#,
    "waveform.badge.magnifyingglass": #"<path d="M1.5 6.5v3M4 4v8M6.5 2v12M9 5v4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="12" cy="11" r="2.3" stroke="currentColor" stroke-width="1.3" fill="none"/><path d="M13.7 12.7l1.6 1.6" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>"#,
    "clock.arrow.circlepath": #"<path d="M2.6 9.5A5.6 5.6 0 1 0 3.4 4.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" fill="none"/><path d="M1.6 2.6l1.8 1.9 2-1.2" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" fill="none"/><path d="M8 5v3.3l2.2 1.4" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" fill="none"/>"#,
    "gear": #"<circle cx="8" cy="8" r="5.4" stroke="currentColor" stroke-width="2.4" stroke-dasharray="2.1 2.14" fill="none"/><circle cx="8" cy="8" r="4.2" stroke="currentColor" stroke-width="1.3" fill="none"/><circle cx="8" cy="8" r="1.6" stroke="currentColor" stroke-width="1.2" fill="none"/>"#,
    "lock.shield": #"<path d="M8 1.3l5.5 2v4.2c0 3.4-2.4 6-5.5 7.2-3.1-1.2-5.5-3.8-5.5-7.2V3.3z" fill="currentColor"/><rect x="5.6" y="7" width="4.8" height="3.6" rx="0.8" fill="white"/><path d="M6.6 7V5.9a1.4 1.4 0 0 1 2.8 0V7" stroke="white" stroke-width="1.1" fill="none"/>"#,
    "arrow.triangle.2.circlepath": #"<path d="M2.5 7.2A5.6 5.6 0 0 1 12.6 4.6M13.5 8.8A5.6 5.6 0 0 1 3.4 11.4" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" fill="none"/><path d="M10.4 4.8h2.4V2.4M5.6 11.2H3.2v2.4" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
    "questionmark.circle": #"<circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.3" fill="none"/><path d="M6.1 6.2a1.9 1.9 0 1 1 2.6 1.8c-.5.2-.7.6-.7 1.1v.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" fill="none"/><circle cx="8" cy="11.4" r=".8" fill="currentColor"/>"#,
    "arrow.up.right.square": #"<rect x="1.5" y="1.5" width="13" height="13" rx="2.5" stroke="currentColor" stroke-width="1.2" fill="none"/><path d="M6 10l4.5-4.5M6.5 5.5h4v4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
    "power": #"<path d="M4.6 4a5.6 5.6 0 1 0 6.8 0M8 1.5v6" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" fill="none"/>"#,
    "waveform.badge.microphone": #"<path d="M1.5 6.5v3M4 3.5v9M6.5 1.5v13M9 4.5v5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><rect x="11" y="6.5" width="3" height="5" rx="1.5" fill="currentColor"/><path d="M10 10.2a2.5 2.5 0 0 0 5 0M12.5 12.7v1.8" stroke="currentColor" stroke-width="1" stroke-linecap="round" fill="none"/>"#,
    "stop.fill": #"<rect x="3" y="3" width="10" height="10" rx="1.5" fill="currentColor"/>"#,
    "slider.horizontal.3": ##"<path d="M1.5 3.5h13M1.5 8h13M1.5 12.5h13" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/><circle cx="10.5" cy="3.5" r="1.7" fill="#2b2b2b" stroke="currentColor" stroke-width="1.2"/><circle cx="5" cy="8" r="1.7" fill="#2b2b2b" stroke="currentColor" stroke-width="1.2"/><circle cx="9" cy="12.5" r="1.7" fill="#2b2b2b" stroke="currentColor" stroke-width="1.2"/>"##,
    "chevron.up": #"<path d="M4 10l4-4 4 4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
    "chevron.left": #"<path d="M10 4L6 8l4 4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
    "doc.text": #"<path d="M4 1.5h5.5L13 5v9.5H4z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" fill="none"/><path d="M6 7.5h5M6 9.8h5M6 12h3.5" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/>"#,
    "globe": #"<circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.2" fill="none"/><ellipse cx="8" cy="8" rx="3" ry="6.5" stroke="currentColor" stroke-width="1.2" fill="none"/><path d="M1.5 8h13" stroke="currentColor" stroke-width="1.2"/>"#,
]

/// All drawings, including those the settings and tool figures add.
let icons = baseIcons.merging(settingsIcons) { base, _ in base }.merging(toolIcons) { base, _ in base }

final class SVG {
    private(set) var body: [String] = []
    /// Gradients and other definitions a figure adds besides the shared shadows.
    var definitions: [String] = []

    func add(_ element: String) { body.append(element) }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat, fill: String, opacity: CGFloat = 1, stroke: String? = nil, strokeOpacity: CGFloat = 1, filter: String? = nil) {
        var e = #"<rect x="\#(f(x))" y="\#(f(y))" width="\#(f(w))" height="\#(f(h))" rx="\#(f(radius))" fill="\#(fill)""#
        if opacity < 1 { e += #" fill-opacity="\#(Double(opacity))""# }
        if let stroke { e += #" stroke="\#(stroke)""# + (strokeOpacity < 1 ? #" stroke-opacity="\#(strokeOpacity)""# : "") }
        if let filter { e += #" filter="url(#\#(filter))""# }
        add(e + "/>")
    }

    /// Text whose line box is centered on `centerY`; returns its width.
    @discardableResult
    func text(_ s: String, x: CGFloat, centerY: CGFloat, _ style: Style, color: String, opacity: CGFloat = 1, anchorEnd: Bool = false) -> CGFloat {
        let font = style.font
        let baseline = centerY + (font.ascender + font.descender) / 2
        let w = width(s, style)
        let left = anchorEnd ? x - w : x
        add(#"<text x="\#(f(left))" y="\#(f(baseline))" font-size="\#(f(font.pointSize))" font-weight="\#(style.weight)" fill="\#(color)"\#(opacity < 1 ? #" fill-opacity="\#(Double(opacity))""# : "")>\#(xml(s))</text>"#)
        return w
    }

    func icon(_ name: String, x: CGFloat, centerY: CGFloat, size: CGFloat, color: String, opacity: CGFloat = 1) {
        guard let shape = icons[name] else { fail("no drawing for the symbol \(name)") }
        let scale = size / 16
        add(#"<g transform="translate(\#(f(x)) \#(f(centerY - size / 2))) scale(\#(scale))" color="\#(color)"\#(opacity < 1 ? #" opacity="\#(Double(opacity))""# : "")>\#(shape)</g>"#)
    }

    func document(width: CGFloat, height: CGFloat, title: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" role="img" width="\(f(width))" height="\(f(height))" viewBox="0 0 \(f(width)) \(f(height))" font-family="-apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'Hiragino Sans', 'Noto Sans JP', Arial, sans-serif">
          <title>\(xml(title))</title>
          <defs>
            <filter id="window-shadow" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#000" flood-opacity="0.18"/></filter>
            <filter id="control-shadow" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="1" stdDeviation="1" flood-color="#000" flood-opacity="0.12"/></filter>\(definitions.map { "\n    " + $0 }.joined())
          </defs>
          \(body.joined(separator: "\n  "))
        </svg>

        """
    }
}

// MARK: - Reading defaults

/// A default shortcut of Services/HotKeyService.swift, written the way
/// KeyCombo.displayString writes it: the modifiers, then the key, which HotKey
/// shows as its character, or as its name in capitals for a letter.
func defaultShortcut(_ name: String) -> String {
    let path = "Services/HotKeyService.swift"
    let text = source(path)
    let regex = try! NSRegularExpression(pattern: #"static let \#(name) = KeyCombo\(key: \.(\w+), modifiers: \[([^\]]*)\]\)"#)
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { fail("\(path) has no \(name)") }
    let key = String(text[Range(match.range(at: 1), in: text)!])
    let characters = ["space": "Space", "slash": "/", "period": ".", "comma": ",", "semicolon": ";", "quote": "'", "minus": "-", "equal": "="]
    return modifierSymbols(String(text[Range(match.range(at: 2), in: text)!])) + (characters[key] ?? key.uppercased())
}

/// Modifier symbols in the order the app writes them: ⌃⌥⇧⌘.
func modifierSymbols(_ text: String) -> String {
    [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")]
        .filter { text.contains($0.0) }.map(\.1).joined()
}

// MARK: - Shared parts of the panels

let margin: CGFloat = 24
let panelWidth: CGFloat = 900
let panelPad: CGFloat = 16
/// The rows of a speech panel: header, text area, translation row, actions.
let panelAreaHeight: CGFloat = 210
let panelHeight = panelPad + 24 + 12 + panelAreaHeight + 12 + 32 + 12 + 34 + panelPad
let panelAreaTop = margin + panelPad + 24 + 12
let panelTranslationY = panelAreaTop + panelAreaHeight + 12 + 16
let panelActionY = panelTranslationY + 16 + 12 + 17

/// The floating panel's surface.
func panelSurface(_ svg: SVG, height: CGFloat) {
    svg.rect(margin, margin, panelWidth, height, radius: 12, fill: Color.window, stroke: "#000", strokeOpacity: 0.12, filter: "window-shadow")
}

/// One of the header's selectors: a label and a value in a tinted badge.
struct Selector {
    let label: String
    let value: String
    var icon: String? = nil
    var tint = Color.accent
    var menu = true
}

/// The panel header: Close, the status icon and title on the left, then the
/// given extra control, and the selectors on the right.
func panelHeader(_ svg: SVG, status: String, title: String, selectors: [Selector], after: ((CGFloat, CGFloat) -> Void)? = nil) {
    let y = margin + panelPad + 12
    var x = margin + panelPad
    svg.icon("xmark.circle.fill", x: x + 4, centerY: y, size: 16, color: "#a1a1a6")
    x += 24 + 8
    svg.icon(status, x: x + 3, centerY: y, size: 18, color: Color.accent)
    x += 24 + 8
    x += svg.text(title, x: x, centerY: y, .headline, color: Color.label) + 8
    after?(x, y)

    var end = margin + panelWidth - panelPad
    for selector in selectors.reversed() {
        let valueStyle: Style = selector.icon == nil ? .calloutMedium : .callout
        let iconWidth: CGFloat = selector.icon == nil ? 0 : 16 + 4
        let badge = 6 + iconWidth + width(selector.value, valueStyle) + 6
        let indicator: CGFloat = selector.menu ? 4 + 9 : 0
        var left = end - indicator - badge
        if selector.menu { svg.icon("chevron.down", x: end - 9, centerY: y, size: 9, color: Color.secondary) }
        svg.rect(left, y - 9, badge, 18, radius: 4, fill: selector.tint, opacity: 0.2)
        if let icon = selector.icon { svg.icon(icon, x: left + 7, centerY: y, size: 14, color: Color.label) }
        svg.text(selector.value, x: left + 6 + iconWidth, centerY: y, valueStyle, color: Color.label)
        left -= 4
        svg.text(selector.label, x: left, centerY: y, .callout, color: Color.secondary, anchorEnd: true)
        end = left - width(selector.label, .callout) - 8
    }
}

/// The text area as the panels draw it, with an optional tint and the state of
/// its text tools.
func textArea(_ svg: SVG, top: CGFloat, height: CGFloat, text: String, fontSize: CGFloat, tint: String? = nil, eraserEnabled: Bool = true) {
    let left = margin + panelPad, areaWidth = panelWidth - panelPad * 2
    svg.rect(left, top, areaWidth, height, radius: 8, fill: Color.textArea, stroke: Color.gray, strokeOpacity: 0.3)
    if let tint { svg.rect(left + 0.5, top + 0.5, areaWidth - 1, height - 1, radius: 8, fill: tint, opacity: 0.05) }
    guard !text.isEmpty else { return }
    let style = Style.text(fontSize)
    let lineHeight = ceil(fontSize * 1.3)
    // Leave a little room for systems that draw text with other fonts.
    for (index, line) in wrap(text, style, limit: (areaWidth - 28) * 0.98).enumerated() {
        svg.text(line, x: left + 14, centerY: top + 12 + lineHeight * (CGFloat(index) + 0.5), style, color: Color.label)
    }
    let sizeLabel = String(Int(fontSize))
    let sizeWidth = max(22, width(sizeLabel, .calloutMedium))
    let toolsWidth = 6 + 24 + sizeWidth + 24 + 2 + 1 + 2 + 24 + 2 + 24 + 6
    let toolsX = left + areaWidth - 8 - toolsWidth
    let y = top + height - 8 - 14
    svg.rect(toolsX, y - 14, toolsWidth, 28, radius: 8, fill: Color.window, filter: "control-shadow")
    var x = toolsX + 6
    svg.icon("minus", x: x + 4.5, centerY: y, size: 15, color: Color.secondary); x += 24
    svg.text(sizeLabel, x: x + (sizeWidth - width(sizeLabel, .calloutMedium)) / 2, centerY: y, .calloutMedium, color: Color.secondary); x += sizeWidth
    svg.icon("plus", x: x + 4.5, centerY: y, size: 15, color: Color.secondary); x += 24 + 2
    svg.add(#"<path d="M\#(f(x + 0.5)) \#(f(y - 7))v14" stroke="black" stroke-opacity="0.15"/>"#); x += 1 + 2
    svg.icon("checkmark.circle", x: x + 4.5, centerY: y, size: 15, color: Color.secondary); x += 24 + 2
    svg.icon("eraser", x: x + 4.5, centerY: y, size: 15, color: Color.secondary, opacity: eraserEnabled ? 1 : 0.4)
}

/// What the translation row's button shows.
enum TranslationButton {
    case translate(enabled: Bool)
    case original
}

/// The translation row in the state given.
func translationRow(_ svg: SVG, _ strings: Strings, centerY y: CGFloat, target: String, button: TranslationButton = .translate(enabled: true)) {
    let view = "Views/Components/TranslationControls.swift"
    var x = margin + panelPad + 4
    x += svg.text(strings.label("Translation:", in: view), x: x, centerY: y, .callout, color: Color.secondary) + 6
    for value in ["→ " + target, caseValue("macOS", in: "Models/TranslationProvider.swift")] {
        let w = svg.text(value, x: x, centerY: y, .calloutMedium, color: Color.label)
        svg.icon("chevron.down", x: x + w + 4, centerY: y, size: 9, color: Color.secondary)
        x += w + 4 + 9 + 6
    }
    switch button {
    case .translate(let enabled):
        let title = strings.label("Translate", in: view)
        let color = enabled ? Color.accent : Color.secondary
        let w = 6 + 12 + 4 + width(title, .calloutMedium) + 6
        svg.rect(x, y - 10, w, 20, radius: 4, fill: enabled ? Color.accent : "#000", opacity: enabled ? 0.12 : 0.05)
        svg.icon("globe", x: x + 6, centerY: y, size: 12, color: color)
        svg.text(title, x: x + 6 + 12 + 4, centerY: y, .calloutMedium, color: color)
    case .original:
        let title = strings.label("Original", in: view)
        let titleWidth = width(title, .calloutMedium)
        let w = 6 + 12 + 4 + titleWidth + 4 + 10 + 6
        svg.rect(x, y - 10, w, 20, radius: 4, fill: Color.accent, opacity: 0.1)
        svg.icon("globe", x: x + 6, centerY: y, size: 12, color: Color.accent)
        svg.text(title, x: x + 6 + 12 + 4, centerY: y, .calloutMedium, color: Color.accent)
        svg.icon("chevron.left", x: x + 6 + 12 + 4 + titleWidth + 3, centerY: y, size: 11, color: Color.accent)
    }
}

/// "N chars / N words", counted as the panels count them.
func countText(_ strings: Strings, _ text: String) -> String {
    let view = "Views/Components/TextCountView.swift"
    return "\(text.count) \(strings.label("chars", in: view)) / \(TextStatistics.wordCount(text)) \(strings.label("words", in: view))"
}

/// A push button with an icon and a title; drawn so that it ends at `right`.
/// Returns its left edge.
func actionButton(_ svg: SVG, right: CGFloat, centerY: CGFloat, title: String, icon: String, prominent: Bool) -> CGFloat {
    let w = 10 + 4 + 13 + 4 + width(title, .body) + 4 + 10
    let x = right - w
    if prominent {
        svg.rect(x, centerY - 16, w, 32, radius: 6, fill: Color.accent)
    } else {
        svg.rect(x, centerY - 16, w, 32, radius: 6, fill: Color.white, stroke: "#000", strokeOpacity: 0.1, filter: "control-shadow")
    }
    let color = prominent ? Color.white : Color.label
    svg.icon(icon, x: x + 14, centerY: centerY, size: 14, color: color)
    svg.text(title, x: x + 14 + 13 + 4, centerY: centerY, .body, color: color)
    return x
}

/// Draws buttons from right to left, ending at the panel's padding.
func actionButtons(_ svg: SVG, centerY: CGFloat, _ buttons: [(title: String, icon: String, prominent: Bool)]) {
    var end = margin + panelWidth - panelPad
    for button in buttons.reversed() {
        end = actionButton(svg, right: end, centerY: centerY, title: button.title, icon: button.icon, prominent: button.prominent) - 8
    }
}

// MARK: - Sample content

let languageNames = "Models/LanguageCode.swift"

/// The language the figures' speech is in, and the one it is translated into.
func languages(_ strings: Strings) -> (spoken: String, target: String) {
    strings.language == "ja"
        ? (caseValue("japanese", in: languageNames), caseValue("english", in: languageNames))
        : (caseValue("english", in: languageNames), caseValue("japanese", in: languageNames))
}

func sample(_ strings: Strings, en: String, ja: String) -> String {
    strings.language == "ja" ? ja : en
}

// MARK: - Panel parts

/// The STT panel's header, with the Panel / Subtitle switch.
func sttHeader(_ svg: SVG, _ strings: Strings) {
    let view = "Views/FloatingWindow/TranscriptionFloatingView.swift"
    panelHeader(svg, status: "waveform", title: strings.label("Speech-to-Text", in: view), selectors: [
        Selector(label: strings.label("Provider:", in: view), value: caseValue("macOS", in: "Services/RealtimeSTT/RealtimeSTTProtocol.swift")),
        Selector(label: strings.label("Language:", in: view), value: languages(strings).spoken, tint: Color.purple),
        Selector(label: strings.label("Input:", in: view), value: strings.label("Microphone", in: view), icon: "mic.fill", tint: Color.blue),
    ]) { x, y in
        let segments = [strings.label("Panel", in: view), strings.label("Subtitle", in: view)]
        let widths = segments.map { width($0, .callout) + 18 }
        svg.rect(x, y - 10, widths.reduce(0, +), 20, radius: 5, fill: "#000", opacity: 0.06)
        svg.rect(x, y - 10, widths[0], 20, radius: 5, fill: Color.accent)
        svg.text(segments[0], x: x + 9, centerY: y, .callout, color: Color.white)
        svg.text(segments[1], x: x + widths[0] + 9, centerY: y, .callout, color: Color.label)
    }
}

/// The TTS panel's header with the default provider, voice, speed and output.
func ttsHeader(_ svg: SVG, _ strings: Strings) {
    let view = "Views/FloatingWindow/TTSFloatingView.swift"
    panelHeader(svg, status: "speaker.wave.2", title: strings.label("Text-to-Speech", in: view), selectors: [
        Selector(label: strings.label("Provider:", in: view), value: caseValue("macOS", in: "Services/TTS/TTSProtocol.swift")),
        Selector(label: strings.label("Voice:", in: view), value: strings.label("Auto (detect language)", in: "Services/TTS/MacOSTTS.swift")),
        Selector(label: strings.label("Speed:", in: view), value: String(format: "%.2fx", 1.0), menu: false),
        Selector(label: strings.label("Output:", in: view), value: strings.label("System Default", in: view), icon: "speaker.wave.2"),
    ])
}

/// The STT panel's Target and Paste group; returns its width.
@discardableResult
func targetGroup(_ svg: SVG, _ strings: Strings, centerY y: CGFloat, selected: Bool, expanded: Bool, pasteEnabled: Bool) -> (width: CGFloat, targetCenter: CGFloat) {
    let view = "Views/FloatingWindow/TranscriptionFloatingView.swift"
    let left = margin + panelPad
    let title = strings.label("Target:", in: view)
    let none = strings.label("None", in: view)
    let valueWidth = selected ? 16 : width(none, .body)
    let targetWidth = 5 + 13 + 4 + width(title, .body) + 4 + valueWidth + 4 + 9 + 5
    let paste = strings.label("Paste", in: view)
    let pasteWidth = 5 + 13 + 4 + width(paste, .body) + 5
    let groupWidth = 4 + targetWidth + 4 + pasteWidth + 4
    svg.rect(left, y - 17, groupWidth, 34, radius: 8, fill: "#000", opacity: 0.04)
    var x = left + 4
    svg.rect(x, y - 13, targetWidth, 26, radius: 4, fill: "#000", opacity: 0.05)
    svg.icon("macwindow", x: x + 5, centerY: y, size: 13, color: Color.label)
    var inner = x + 5 + 13 + 4
    inner += svg.text(title, x: inner, centerY: y, .body, color: Color.label) + 4
    if selected {
        appIcon(svg, x: inner, centerY: y, size: 16, tint: "#8e9aaf")
        inner += 16 + 4
    } else {
        inner += svg.text(none, x: inner, centerY: y, .body, color: Color.label) + 4
    }
    svg.icon(expanded ? "chevron.up" : "chevron.down", x: inner, centerY: y, size: 9, color: Color.secondary)
    let targetCenter = x + targetWidth / 2
    x += targetWidth + 4
    faded(svg, pasteEnabled ? 1 : 0.4) {
        svg.rect(x, y - 13, pasteWidth, 26, radius: 4, fill: "#000", opacity: 0.05)
        svg.icon("doc.on.clipboard", x: x + 5, centerY: y, size: 13, color: Color.label)
        svg.text(paste, x: x + 5 + 13 + 4, centerY: y, .body, color: Color.label)
    }
    return (groupWidth, targetCenter)
}

/// A neutral app icon: a tinted rounded square with a document glyph. It stands
/// for whatever app owns a window, without drawing any real app's icon.
func appIcon(_ svg: SVG, x: CGFloat, centerY: CGFloat, size: CGFloat, tint: String) {
    svg.rect(x, centerY - size / 2, size, size, radius: size * 0.22, fill: tint)
    svg.icon("doc.text", x: x + size * 0.15, centerY: centerY, size: size * 0.7, color: Color.white)
}

/// Draws `body` at reduced opacity, as a disabled control appears.
func faded(_ svg: SVG, _ opacity: CGFloat, _ body: () -> Void) {
    svg.add(#"<g opacity="\#(opacity)">"#)
    body()
    svg.add("</g>")
}

// MARK: - Figures

/// The Speech-to-Text panel with a finished transcription, in the floating style.
func sttPanel(_ strings: Strings) -> String {
    let view = "Views/FloatingWindow/TranscriptionFloatingView.swift"
    let text = sample(strings,
        en: "SpeechDock turns what you say into text in any app. Pick a provider and a language, press Record, and speak. When you stop, paste the text into the window you chose, save it, or translate it first.",
        ja: "SpeechDock は、話した言葉をどのアプリでも文字にします。プロバイダと言語を選んで録音を押し、話してください。止めたら、選んだウィンドウに貼り付けるか、保存するか、翻訳できます。")
    let svg = SVG()
    panelSurface(svg, height: panelHeight)
    sttHeader(svg, strings)
    textArea(svg, top: panelAreaTop, height: panelAreaHeight, text: text, fontSize: 18)
    translationRow(svg, strings, centerY: panelTranslationY, target: languages(strings).target)
    let group = targetGroup(svg, strings, centerY: panelActionY, selected: false, expanded: false, pasteEnabled: true)
    svg.text(countText(strings, text), x: margin + panelPad + group.width + 8, centerY: panelActionY, .callout, color: Color.secondary)
    actionButtons(svg, centerY: panelActionY, [
        (strings.label("Record", in: view), "mic.fill", true),
        (strings.label("Save Text", in: view), "square.and.arrow.down", false),
        (strings.label("Copy", in: view), "doc.on.doc", false),
    ])
    return svg.document(width: panelWidth + margin * 2, height: panelHeight + margin * 2, title: strings.label("Speech-to-Text", in: view))
}

/// The Text-to-Speech panel with text ready to be read, in the floating style.
func ttsPanel(_ strings: Strings) -> String {
    let view = "Views/FloatingWindow/TTSFloatingView.swift"
    let text = sample(strings,
        en: "Select text in any app and press the shortcut, and SpeechDock reads it aloud. You can also type or paste text here, capture text on the screen with OCR, or save the speech as an audio file.",
        ja: "どのアプリでも文字を選んでショートカットを押すと、SpeechDock が読み上げます。ここに入力や貼り付けもでき、画面の文字を OCR で取り込んだり、音声をファイルに保存したりもできます。")
    let svg = SVG()
    panelSurface(svg, height: panelHeight)
    ttsHeader(svg, strings)
    textArea(svg, top: panelAreaTop, height: panelAreaHeight, text: text, fontSize: 18)
    translationRow(svg, strings, centerY: panelTranslationY, target: languages(strings).target)

    var x = margin + panelPad + 8
    svg.icon("text.viewfinder", x: x, centerY: panelActionY, size: 14, color: Color.secondary)
    x += 14 + 4
    x += svg.text(strings.label("OCR", in: view), x: x, centerY: panelActionY, .callout, color: Color.secondary) + 8 + 12
    svg.text(countText(strings, text), x: x, centerY: panelActionY, .callout, color: Color.secondary)
    actionButtons(svg, centerY: panelActionY, [
        (strings.label("Speak", in: view), "speaker.wave.2.fill", true),
        (strings.label("Save Audio", in: view), "square.and.arrow.down", false),
    ])
    return svg.document(width: panelWidth + margin * 2, height: panelHeight + margin * 2, title: strings.label("Text-to-Speech", in: view))
}

/// The menu bar menu with nothing running.
func menuBar(_ strings: Strings) -> String {
    let view = "Views/MenuBarView.swift"
    let updates = "Services/SparkleUpdater.swift"
    let menuWidth: CGFloat = 280, inset: CGFloat = 6
    let svg = SVG()
    var rows: [(SVG, CGFloat) -> CGFloat] = []   // each draws at a top and returns its height
    let left = margin + inset, right = margin + menuWidth - inset

    func badge(_ text: String, right: CGFloat, centerY: CGFloat) -> CGFloat {
        let style = Style.sized(12, .medium)
        let w = 6 + width(text, style) + 6
        svg.rect(right - w, centerY - 9.5, w, 19, radius: 4, fill: "#000", opacity: 0.075)
        svg.text(text, x: right - 6, centerY: centerY, style, color: Color.secondary, anchorEnd: true)
        return right - w
    }
    func item(_ icon: String, _ title: String, state: String? = nil, shortcut: String? = nil, detail: String? = nil, trailingIcon: String? = nil, chevron: Bool = false) {
        rows.append { svg, top in
            let content = detail == nil ? max(Style.body.lineHeight, shortcut == nil ? 0 : 19) : Style.body.lineHeight + 1 + Style.callout.lineHeight
            let height = content + 8
            let y = top + height / 2
            svg.icon(icon, x: left + 8 + 2, centerY: y, size: 16, color: Color.accent)
            let textX = left + 8 + 20 + 8
            if let detail {
                let titleY = top + 4 + Style.body.lineHeight / 2
                svg.text(title, x: textX, centerY: titleY, .body, color: Color.label)
                svg.text(detail, x: textX, centerY: titleY + Style.body.lineHeight / 2 + 1 + Style.callout.lineHeight / 2, .callout, color: Color.secondary)
            } else {
                let w = svg.text(title, x: textX, centerY: y, .body, color: Color.label)
                if chevron { svg.icon("chevron.down", x: textX + w + 5, centerY: y, size: 9, color: Color.secondary) }
            }
            var end = right - 8
            if let shortcut { end = badge(shortcut, right: end, centerY: y) - 8 }
            if let state { svg.text(state, x: end, centerY: y, .callout, color: Color.secondary, anchorEnd: true) }
            if let trailingIcon { svg.icon(trailingIcon, x: end - 12, centerY: y, size: 12, color: Color.secondary) }
            return height
        }
    }
    func heading(_ title: String) {
        rows.append { svg, top in
            let style = Style.sized(12, .semibold)
            let height = style.lineHeight + 4
            svg.text(title, x: left + 8, centerY: top + height / 2, style, color: Color.secondary)
            return height
        }
    }
    func divider() {
        rows.append { svg, top in
            svg.add(#"<path d="M\#(f(left + 4)) \#(f(top + 4.5))H\#(f(right - 4))" stroke="black" stroke-opacity="0.1"/>"#)
            return 9
        }
    }

    let off = strings.label("Off", in: view)
    rows.append { svg, top in
        let height: CGFloat = 6 + 22 + 4
        let y = top + 6 + 11
        svg.icon("waveform.badge.microphone", x: left + 4, centerY: y, size: 20, color: Color.accent)
        svg.text(strings.name("SpeechDock", in: view), x: left + 4 + 20 + 8, centerY: y, .headline, color: Color.label)
        return height
    }
    divider()
    heading(strings.label("Speech-to-Text", in: view))
    item("record.circle", strings.label("Transcription", in: view), shortcut: defaultShortcut("sttDefault"))
    item("captions.bubble", strings.label("Subtitle Mode", in: view), state: off, shortcut: defaultShortcut("subtitleDefault"))
    item("mic.circle", strings.label("Floating Mic Button", in: view), state: off, shortcut: defaultShortcut("quickTranscriptionDefault"))
    item("waveform.badge.magnifyingglass", strings.label("Transcribe Audio File...", in: view),
         detail: strings.label("Apple Speech (offline, max 100MB)", in: "Services/RealtimeSTT/RealtimeSTTProtocol.swift"))
    item("clock.arrow.circlepath", strings.label("Transcription History", in: view), chevron: true)
    divider()
    heading(strings.label("Text-to-Speech", in: view))
    item("speaker.wave.2", strings.label("Text to Speech", in: view), shortcut: defaultShortcut("ttsDefault"))
    item("text.viewfinder", strings.label("OCR Region to TTS", in: view), shortcut: defaultShortcut("ocrDefault"))
    divider()
    item("gear", strings.label("Settings...", in: view), shortcut: "⌘,")
    item("lock.shield", strings.label("Permissions...", in: view))
    item("arrow.triangle.2.circlepath", strings.label("Check for Updates...", in: updates))
    item("questionmark.circle", strings.label("Help & Documentation", in: view), trailingIcon: "arrow.up.right.square")
    divider()
    item("power", strings.label("Quit SpeechDock", in: view))

    // Lay the rows out once to learn the height, then draw the menu behind them.
    let measure = SVG()
    var total: CGFloat = 0
    for row in rows { total += row(measure, margin + inset + total) + 2 }
    let height = total - 2 + inset * 2
    svg.rect(margin, margin, menuWidth, height, radius: 10, fill: "#f6f6f6", stroke: "#000", strokeOpacity: 0.12, filter: "window-shadow")
    var top = margin + inset
    for row in rows { top += row(svg, top) + 2 }
    return svg.document(width: menuWidth + margin * 2, height: height + margin * 2, title: strings.name("SpeechDock", in: view))
}

/// Subtitles over a desktop while recording, with translation on.
func subtitleOverlay(_ strings: Strings) -> String {
    let view = "Views/Subtitle/SubtitleOverlayView.swift"
    let state = "App/AppState.swift"
    let fontSize = CGFloat(Double(defaultValue("subtitleFontSize", in: state))!)
    let textOpacity = CGFloat(Double(defaultValue("subtitleOpacity", in: state))!)
    let backgroundOpacity = CGFloat(Double(defaultValue("subtitleBackgroundOpacity", in: state))!)
    let language = languages(strings)
    let spoken = sample(strings, en: "Pick a provider and a language, press Record, and speak.", ja: "プロバイダと言語を選んで録音を押し、話してください。")
    let translated = sample(strings, en: "プロバイダと言語を選んで録音を押し、話してください。", ja: "Pick a provider and a language, press Record, and speak.")

    let canvasWidth: CGFloat = 1000, overlayWidth: CGFloat = 840
    let originalSize = fontSize * 0.7
    let overlayHeight = 16 + 24 + 8 + ceil(originalSize * 1.4) + 8 + ceil(fontSize * 1.3) + 16
    let canvasHeight = overlayHeight + 170
    let svg = SVG()
    svg.definitions.append(##"<linearGradient id="desktop" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2d3a5c"/><stop offset="0.6" stop-color="#6a5a72"/><stop offset="1" stop-color="#b98d72"/></linearGradient>"##)
    svg.rect(0, 0, canvasWidth, canvasHeight, radius: 0, fill: "url(#desktop)")
    svg.add(##"<path d="M0 \##(f(canvasHeight * 0.72)) C 300 \##(f(canvasHeight * 0.6)), 650 \##(f(canvasHeight * 0.66)), 1000 \##(f(canvasHeight * 0.8)) V \##(f(canvasHeight)) H 0 Z" fill="#26332b"/>"##)

    let left = (canvasWidth - overlayWidth) / 2, top = canvasHeight - overlayHeight - 40
    svg.rect(left, top, overlayWidth, overlayHeight, radius: 12, fill: "#000", opacity: backgroundOpacity)
    svg.rect(left + overlayWidth / 2 - 18, top + 6, 36, 4, radius: 2, fill: "#fff", opacity: 0.6)

    // Header: Close, recording, Stop; translation and controls on the right
    let y = top + 16 + 12
    var x = left + 24
    svg.icon("xmark.circle.fill", x: x, centerY: y, size: 16, color: "#1f1f1f")
    x += 16 + 12
    svg.add(##"<circle cx="\##(f(x + 5))" cy="\##(f(y))" r="5" fill="#ff3b30"/>"##)
    x += 10 + 6
    x += svg.text(strings.label("Recording", in: view), x: x, centerY: y, .sized(15, .regular), color: "#fff", opacity: 0.6) + 6
    let stop = strings.label("Stop", in: view)
    let stopWidth = 8 + 12 + 4 + width(stop, .sized(13, .medium)) + 8
    svg.rect(x, y - 11, stopWidth, 22, radius: 4, fill: "#fff", opacity: 0.15)
    svg.icon("stop.fill", x: x + 8, centerY: y, size: 12, color: "#fff", opacity: 0.7)
    svg.text(stop, x: x + 8 + 12 + 4, centerY: y, .sized(13, .medium), color: "#fff", opacity: 0.7)

    var end = left + overlayWidth - 24
    svg.icon("slider.horizontal.3", x: end - 14, centerY: y, size: 14, color: "#fff", opacity: 0.5)
    end -= 14 + 12
    svg.icon("chevron.down", x: end - 9, centerY: y, size: 9, color: "#fff", opacity: 0.4)
    end -= 9 + 4
    end -= svg.text(language.target, x: end, centerY: y, .sized(12, .medium), color: "#fff", opacity: 0.6, anchorEnd: true) + 6
    end -= svg.text("→", x: end, centerY: y, .sized(12, .regular), color: "#fff", opacity: 0.3, anchorEnd: true) + 6
    svg.icon("chevron.down", x: end - 9, centerY: y, size: 9, color: "#fff", opacity: 0.4)
    end -= 9 + 4
    end -= svg.text(caseValue("macOS", in: "Models/TranslationProvider.swift"), x: end, centerY: y, .sized(12, .regular), color: "#fff", opacity: 0.6, anchorEnd: true) + 6
    svg.icon("globe", x: end - 14, centerY: y, size: 14, color: Color.blue)

    // The spoken text, small, above its translation
    let originalY = top + 16 + 24 + 8 + ceil(originalSize * 1.4) / 2
    svg.text(spoken, x: left + 24, centerY: originalY, .sized(originalSize, .regular), color: "#fff", opacity: textOpacity * 0.6)
    let translatedY = originalY + ceil(originalSize * 1.4) / 2 + 8 + ceil(fontSize * 1.3) / 2
    svg.text(translated, x: left + 24, centerY: translatedY, .sized(fontSize, .medium), color: "#fff", opacity: textOpacity)
    return svg.document(width: canvasWidth, height: canvasHeight, title: strings.label("Subtitle Mode", in: "Views/MenuBarView.swift"))
}

/// The initial value of a stored property, as in `var subtitleFontSize: Double = 28.0 {`.
func defaultValue(_ name: String, in path: String) -> String {
    let text = source(path)
    let regex = try! NSRegularExpression(pattern: #"var \#(name): \w+ = ([^\s{]+)"#)
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { fail("\(path) has no \(name)") }
    return String(text[Range(match.range(at: 1), in: text)!])
}

// MARK: - Output

typealias Figure = (name: String, draw: (Strings) -> String)

let panelFigures: [Figure] = [
    ("stt-panel", sttPanel),
    ("tts-panel", ttsPanel),
    ("menu-bar", menuBar),
    ("subtitle-overlay", subtitleOverlay),
]

/// Every figure; the settings and tool figures are drawn in their own files.
let figures = panelFigures + settingsFigures + toolFigures

@main
enum GenerateDocFigures {
    static func main() {
        let outputRoot = CommandLine.arguments.dropFirst().first ?? "docs/images"
        for language in ["en", "ja"] {
            let strings = Strings(language: language, table: localizedStrings(language))
            let directory = language == "en" ? outputRoot : "\(outputRoot)/\(language)"
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for figure in figures {
                let path = "\(directory)/\(figure.name).svg"
                do {
                    try figure.draw(strings).write(toFile: path, atomically: true, encoding: .utf8)
                } catch {
                    fail("cannot write \(path): \(error.localizedDescription)")
                }
                print(path)
            }
        }
    }
}

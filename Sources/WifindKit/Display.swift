import Foundation

/// Display-width helpers so columns stay aligned with CJK and emoji SSIDs.
///
/// Lives in the kit rather than the UI target so the width rules can be
/// unit tested without a terminal.
public enum Display {
    public static func width(_ text: String) -> Int {
        var total = 0
        for scalar in text.unicodeScalars {
            total += width(scalar)
        }
        return total
    }

    static func width(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        switch value {
        case 0x0300...0x036F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20F0, 0xFE00...0xFE0F, 0xFE20...0xFE2F:
            return 0 // combining marks and variation selectors
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    public static func truncate(_ text: String, width limit: Int) -> String {
        guard limit > 0 else { return "" }
        if width(text) <= limit { return text }
        var out = ""
        var used = 0
        for character in text {
            let charWidth = width(String(character))
            if used + charWidth > max(0, limit - 1) { break }
            out.append(character)
            used += charWidth
        }
        return out + "\u{2026}"
    }

    public static func pad(_ text: String, width limit: Int, alignRight: Bool = false) -> String {
        let clipped = truncate(text, width: limit)
        let padding = max(0, limit - width(clipped))
        return alignRight ? String(repeating: " ", count: padding) + clipped : clipped + String(repeating: " ", count: padding)
    }

    // MARK: - styled text

    /// Visible width of text that may contain SGR escape sequences.
    ///
    /// The plain `width(_:)` above counts escape bytes as if they were
    /// printable, which is wrong for anything the UI has already coloured. A
    /// line whose visible parts fit but whose escapes push the byte count over
    /// the terminal width still wraps, so the renderer has to measure the way
    /// the terminal does.
    public static func visibleWidth(_ text: String) -> Int {
        var total = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == escape {
                index = endOfEscape(text, from: index)
                continue
            }
            let next = text.index(after: index)
            total += width(String(text[index..<next]))
            index = next
        }
        return total
    }

    /// Clamps styled text to `limit` visible columns.
    ///
    /// Escape sequences are copied through untouched and never counted, so the
    /// result cannot wrap, whatever the terminal width is. When the text has to
    /// be cut, an ellipsis and a reset are appended so a half-finished colour
    /// cannot bleed into the next line.
    public static func truncateVisible(_ text: String, width limit: Int) -> String {
        guard limit > 0 else { return "" }
        if visibleWidth(text) <= limit { return text }
        var out = ""
        var used = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == escape {
                let end = endOfEscape(text, from: index)
                out += text[index..<end]
                index = end
                continue
            }
            let next = text.index(after: index)
            let cellWidth = width(String(text[index..<next]))
            if used + cellWidth > limit - 1 { break }
            out += text[index..<next]
            used += cellWidth
            index = next
        }
        return out + "\u{2026}" + reset
    }

    static let escape = Character("\u{1B}")
    static let reset = "\u{1B}[0m"

    /// Index just past the escape sequence that starts at `index`.
    /// Handles CSI (ESC [ ... letter) and short two-character escapes.
    static func endOfEscape(_ text: String, from index: String.Index) -> String.Index {
        var cursor = text.index(after: index)
        guard cursor < text.endIndex else { return cursor }
        guard text[cursor] == "[" else { return cursor }
        cursor = text.index(after: cursor)
        while cursor < text.endIndex, !text[cursor].isLetter {
            cursor = text.index(after: cursor)
        }
        if cursor < text.endIndex { cursor = text.index(after: cursor) }
        return cursor
    }

    /// Wraps plain text to `columns` display columns, at most `maxLines` lines,
    /// preferring word boundaries. Text that still does not fit is cut and the
    /// last line ends with an ellipsis.
    ///
    /// Kept here rather than in the renderer so the wrapping rules can be
    /// tested without a terminal.
    public static func wrap(_ text: String, columns: Int, maxLines: Int) -> [String] {
        guard columns > 0, maxLines > 0, !text.isEmpty else { return [] }
        var lines: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty, lines.count < maxLines {
            if width(String(rest)) <= columns {
                lines.append(String(rest))
                rest = Substring("")
                break
            }
            var cut = rest.startIndex
            var used = 0
            for character in rest {
                let cellWidth = width(String(character))
                if used + cellWidth > columns { break }
                used += cellWidth
                cut = rest.index(after: cut)
            }
            if let space = rest[..<cut].lastIndex(of: " "),
               rest.distance(from: rest.startIndex, to: space) > columns / 2 {
                cut = space
            }
            lines.append(String(rest[..<cut]))
            rest = rest[cut...].drop { $0 == " " }
        }
        if !rest.isEmpty, let last = lines.last {
            lines[lines.count - 1] = truncate(last + " \u{2026}", width: columns)
        }
        return lines
    }
}

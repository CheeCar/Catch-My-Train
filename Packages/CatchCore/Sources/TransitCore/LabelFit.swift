import Foundation

/// Whether short names fit under a row of icons, each in a column of the same width, on up to two lines: the menu bar panel's
/// bottom row. A name that can't be shown whole would be cut short with "…", so that row then shows its icons alone.
public enum LabelFit {
    /// A part of a name that is never broken over two lines: a word, or one character of a script written without spaces
    public struct Piece: Equatable, Sendable {
        public var width: Double
        /// The room before it when it follows another piece on a line: a space before a word, nothing between the characters
        /// of one word
        public var gap: Double

        public init(width: Double, gap: Double) {
            self.width = width
            self.gap = gap
        }
    }

    /// A name's pieces, measured with `width` (the width of a text in the font the name is drawn in). A word in Chinese or
    /// Japanese may be broken after any character, so each of its characters is a piece of its own
    public static func pieces(of name: String, width: (String) -> Double) -> [Piece] {
        let space = width(" ")
        var pieces: [Piece] = []
        for word in name.split(separator: " ") {
            if word.unicodeScalars.contains(where: breaksAnywhere) {
                for (index, character) in word.enumerated() {
                    pieces.append(Piece(width: width(String(character)), gap: index == 0 ? space : 0))
                }
            } else {
                pieces.append(Piece(width: width(String(word)), gap: space))
            }
        }
        return pieces
    }

    /// Han characters and the Japanese kana: text in them is written without spaces and may be broken between any two
    static func breaksAnywhere(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    /// How many lines of `width` the pieces take, each line taking as many of them as fit. Nil when one piece alone is wider
    /// than a line
    public static func lines(_ pieces: [Piece], width: Double) -> Int? {
        var used = 0.0
        var count = 0
        for piece in pieces {
            guard piece.width <= width else { return nil }
            if count > 0, used + piece.gap + piece.width <= width {
                used += piece.gap + piece.width
            } else {
                count += 1
                used = piece.width
            }
        }
        return count
    }

    /// The pieces fit on at most `lines` lines of `width`. False when one piece alone is wider than a line
    public static func fits(_ pieces: [Piece], width: Double, lines limit: Int = 2) -> Bool {
        guard let count = lines(pieces, width: width) else { return false }
        return count <= limit
    }
}

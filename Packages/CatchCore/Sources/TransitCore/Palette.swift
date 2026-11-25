import Foundation

/// The light-mode values (0xRRGGBB) of the app's own colors (the palette in Shared/UIText.swift uses these), kept here so the
/// contrast and color-blindness checks run with the package's tests. Dark mode uses system colors (see PaletteHex.darkSystem)
public enum PaletteHex {
    public static let noticeOrangeLight: UInt32 = 0xB35C00
    public static let noticeRedLight: UInt32 = 0xC62828
    public static let noticeGreenLight: UInt32 = 0x1B6E2F
    public static let walkRangeLight: UInt32 = 0x0F7B6C
    public static let favoriteStarLight: UInt32 = 0x9A6B00
    public static let metroNameLight: UInt32 = 0x8A3FB0

    /// macOS's dark-mode system colors the palette uses (sRGB), and the dark window background, for the same checks
    public enum DarkSystem {
        public static let orange: UInt32 = 0xFF9F0A
        public static let red: UInt32 = 0xFF453A
        public static let green: UInt32 = 0x30D158
        public static let mint: UInt32 = 0x63E6E2
        public static let yellow: UInt32 = 0xFFD60A
        public static let purple: UInt32 = 0xBF5AF2
        public static let windowBackground: UInt32 = 0x1E1E1E
    }
}

/// How two colors compare: contrast (WCAG 2), and how far apart they look with each kind of color blindness
public enum ColorVision {
    public enum Deficiency: CaseIterable, Sendable {
        case protan, deutan, tritan
    }

    /// Contrast ratio of two colors (1 to 21)
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// How far apart two colors look (CIE76 color difference in Lab; about 2 is just noticeable, over 20 is clearly different),
    /// as seen with full-strength color blindness of the given kind (Machado, Oliveira and Fernandes 2009), or with normal vision
    public static func difference(_ a: UInt32, _ b: UInt32, seenWith deficiency: Deficiency? = nil) -> Double {
        let (la, lb) = (lab(simulate(a, deficiency)), lab(simulate(b, deficiency)))
        return ((la.0 - lb.0) * (la.0 - lb.0) + (la.1 - lb.1) * (la.1 - lb.1) + (la.2 - lb.2) * (la.2 - lb.2)).squareRoot()
    }

    /// The smallest difference over the three kinds of color blindness
    public static func worstDifference(_ a: UInt32, _ b: UInt32) -> Double {
        Deficiency.allCases.map { difference(a, b, seenWith: $0) }.min() ?? 0
    }

    // MARK: - Internals

    private static func channels(_ c: UInt32) -> (Double, Double, Double) {
        (Double(c >> 16 & 0xFF) / 255, Double(c >> 8 & 0xFF) / 255, Double(c & 0xFF) / 255)
    }

    private static func toLinear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }

    private static func luminance(_ c: UInt32) -> Double {
        // WCAG 2's own threshold (0.03928) differs from sRGB's in the fourth decimal; kept as WCAG writes it
        func channel(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let (r, g, b) = channels(c)
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Linear-light RGB as seen with the deficiency (severity 1.0 matrices from Machado et al. 2009)
    private static func simulate(_ c: UInt32, _ deficiency: Deficiency?) -> (Double, Double, Double) {
        let (r, g, b) = channels(c)
        let lin = (toLinear(r), toLinear(g), toLinear(b))
        let m: [[Double]]
        switch deficiency {
        case nil: return lin
        case .protan?: m = [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]
        case .deutan?: m = [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]
        case .tritan?: m = [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]]
        }
        func row(_ i: Int) -> Double { min(1, max(0, m[i][0] * lin.0 + m[i][1] * lin.1 + m[i][2] * lin.2)) }
        return (row(0), row(1), row(2))
    }

    /// CIE Lab (D65) of linear-light RGB
    private static func lab(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        let x = (0.4124 * c.0 + 0.3576 * c.1 + 0.1805 * c.2) / 0.95047
        let y = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
        let z = (0.0193 * c.0 + 0.1192 * c.1 + 0.9505 * c.2) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
}

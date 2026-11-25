import AppKit
import CatchText
import SwiftUI
import TransitCore
import WidgetKit

/// Round line badge.
struct RouteBadge: View {
    var route: String
    var size: CGFloat = 22
    /// Scales with Text size in Settings (always 1 in the widget)
    private var scaled: CGFloat { size * TextScale.factor }

    /// When the desktop widget isn't in front, macOS removes color (only one color remains), and a filled badge becomes an unreadable white square.
    /// In that case switch to outline plus text (the squares in the widget must still show which line they are).
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .fullColor {
            colorBadge
        } else {
            outlineBadge
        }
    }

    /// Badge without color: line name + outline. Circle for subway, rounded rectangle for others.
    private var outlineBadge: some View {
        let label = Self.label(route)
        let round = Self.isSubway(route)
        return Text(label)
            .font(.system(size: scaled * (round ? (label.count > 1 ? 0.38 : 0.6) : 0.4), weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, round ? 0 : scaled * 0.16)
            .frame(minWidth: scaled, minHeight: round ? scaled : scaled * 0.82)
            .overlay {
                if round {
                    Circle().strokeBorder(.primary, lineWidth: 1.2)
                } else {
                    RoundedRectangle(cornerRadius: scaled * 0.16).strokeBorder(.primary, lineWidth: 1.2)
                }
            }
            // Read as the route's name, like the colored badges ("LIRR Babylon Branch", not the badge's "BAB")
            .accessibilityLabel(Text(FerryFeed.spokenRouteName(route)))
    }

    static func isSubway(_ route: String) -> Bool {
        !(RooseveltIslandTram.isTram(route: route) || FerryFeed.isPathRoute(route) || FerryFeed.isRailRoute(route)
          || FerryFeed.isNJBusRoute(route) || FerryFeed.isFerryRoute(route) || BusCatalog.isBusRoute(route))
    }

    /// Text on the badge (same as with color)
    static func label(_ route: String) -> String {
        if RooseveltIslandTram.isTram(route: route) { return "TRAM" }
        if FerryFeed.isPathRoute(route) || FerryFeed.isRailRoute(route) || FerryFeed.isNJBusRoute(route) || FerryFeed.isFerryRoute(route) {
            return FerryFeed.badge(route)
        }
        if BusCatalog.isBusRoute(route) { return route.hasSuffix("+") ? String(route.dropLast()) + "-SBS" : route }
        return MTARoute.badge(route)
    }

    @ViewBuilder private var colorBadge: some View {
        if RooseveltIslandTram.isTram(route: route) {
            TramRouteBadge(size: scaled)
        } else if FerryFeed.isPathRoute(route) {
            PathRouteBadge(route: route, size: scaled)
        } else if FerryFeed.isRailRoute(route) {
            RailRouteBadge(route: route, size: scaled)
        } else if FerryFeed.isNJBusRoute(route) {
            // NJ Transit bus: rounded rectangle with the route number (e.g. "107"), in NJ Transit blue
            RailRouteBadge(route: route, size: scaled)
        } else if FerryFeed.isFerryRoute(route) {
            FerryRouteBadge(route: route, size: scaled)
        } else if BusCatalog.isBusRoute(route) {
            BusRouteBadge(route: route, size: scaled)
        } else {
            subwayBadge
        }
    }

    private var subwayBadge: some View {
        let label = MTARoute.badge(route)
        return Text(label)
            .font(.system(size: scaled * (label.count > 1 ? 0.38 : 0.6), weight: .bold, design: .rounded))
            .foregroundStyle(RouteColor.textColor(for: route))
            .frame(width: scaled, height: scaled)
            .background(Circle().fill(RouteColor.color(for: route)))
            .accessibilityLabel(Text(label))
    }
}

/// PATH line badge: rounded rectangle with the short names of both terminals (e.g. "NWK-WTC"), using each line's color from PATH official data.
struct PathRouteBadge: View {
    var route: String
    var size: CGFloat = 22

    var body: some View {
        let label = FerryFeed.badge(route)
        Text(label)
            .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(Self.darkText.contains(route) ? Color.black : Color.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size * 0.16)
            .frame(minWidth: size, minHeight: size * 0.82)
            .background(RoundedRectangle(cornerRadius: size * 0.12).fill(Self.color(route)))
            .accessibilityLabel(Text(FerryFeed.routeName(route)))
    }

    /// Line colors from PATH official data (routes.txt, ridepath.json)
    static let colors: [String: UInt32] = [
        "PATH-NWK-WTC": 0xD93A30, "PATH-HOB-WTC": 0x65C100, "PATH-JSQ-33": 0xFF9900, "PATH-HOB-33": 0x4D92FB,
        "PATH-JSQ-HOB-33": 0xFF9900, "PATH-NWK-HAR": 0x8C3C96, "PATH-WTC-33": 0x65C100,
    ]
    /// Dark text on light backgrounds (same as official data)
    static let darkText: Set<String> = ["PATH-HOB-WTC", "PATH-JSQ-33", "PATH-HOB-33", "PATH-JSQ-HOB-33"]

    static func color(_ route: String) -> Color {
        // Every Amtrak line uses Amtrak's dark blue
        let v = colors[route] ?? (route.hasPrefix("AMK-") || route.hasPrefix("AMJ-") ? 0x00537E : 0x0039A6)
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Roosevelt Island Tram badge: red rounded tag reading "TRAM" (the cabins are red, and it's red on the map too).
struct TramRouteBadge: View {
    var size: CGFloat = 22

    var body: some View {
        Text("TRAM")
            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size * 0.18)
            .frame(minWidth: size, minHeight: size * 0.82)
            .background(Capsule().fill(Color(red: 0.835, green: 0.169, blue: 0.118)))   // D52B1E
            .accessibilityLabel(Text("Roosevelt Island Tram"))
    }
}

/// Bus route badge: rounded rectangle, like on bus stop signs.
/// Regular buses are blue, Select Bus Service (route number with "+", shown as "-SBS") light blue, bus rapid transit green.
struct BusRouteBadge: View {
    var route: String
    var size: CGFloat = 22

    var body: some View {
        let service = BusCatalog.service(ofRoute: route)
        let label = route.hasSuffix("+") ? String(route.dropLast()) + "-SBS" : route
        Text(label)
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size * 0.18)
            .frame(minWidth: size, minHeight: size * 0.82)
            .background(RoundedRectangle(cornerRadius: size * 0.18).fill(Self.color(service)))
            .accessibilityLabel(Text(label))
    }

    static func color(_ s: BusService) -> Color {
        switch s {
        case .selectBus: return Color(red: 0.0, green: 0.63, blue: 0.87)
        case .express: return Color(red: 0.0, green: 0.58, blue: 0.24)
        case .local, .limited: return Color(red: 0.0, green: 0.22, blue: 0.65)
        }
    }
}

/// Rail line badge: rounded rectangle with the line's short name (e.g. "BAB" for LIRR Babylon Branch, "HUD" for Metro-North Hudson Line),
/// using each line's color from MTA official data (same as the map).
struct RailRouteBadge: View {
    var route: String
    var size: CGFloat = 22

    var body: some View {
        let label = FerryFeed.badge(route)
        Text(label)
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(Self.darkText.contains(route) || RegionalBusFeed.darkText(route: route) ? Color.black : Color.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size * 0.16)
            .frame(minWidth: size, minHeight: size * 0.82)
            .background(RoundedRectangle(cornerRadius: size * 0.12).fill(Self.color(route)))
            .accessibilityLabel(Text(FerryFeed.routeName(route)))
    }

    /// Line colors from LIRR and Metro-North official data (routes.txt)
    static let colors: [String: UInt32] = [
        "LIRR-BAB": 0x00985F, "LIRR-HEM": 0xCE8E00, "LIRR-OB": 0x00AF3F, "LIRR-RON": 0xA626AA,
        "LIRR-MTK": 0x00B2A9, "LIRR-LB": 0xFF6319, "LIRR-FR": 0x6E3219, "LIRR-WH": 0x00A1DE,
        "LIRR-PW": 0xC60C30, "LIRR-PJ": 0x006EC7, "LIRR-BEL": 0x60269E, "LIRR-CTZ": 0x4D5357,
        "LIRR-GP": 0xA626AA,
        "MNR-HUD": 0x009B3A, "MNR-HAR": 0x0039A6, "MNR-NH": 0xEE0034, "MNR-NC": 0xEE0034,
        "MNR-DAN": 0xEE0034, "MNR-WTB": 0xEE0034,
        // NJ Transit (colors from rail_data.zip)
        "NJT-ACL": 0x075AAA, "NJT-MOB": 0xE66859, "NJT-MBL": 0xFFD411, "NJT-PJL": 0xFFD411, "NJT-M&E": 0x08A652,
        "NJT-GLA": 0xA4C9AA, "NJT-MRL": 0xC1AA72, "NJT-NEC": 0xDD3439, "NJT-NJC": 0x03A3DF, "NJT-PVL": 0x94219A,
        "NJT-PRI": 0xDD3439, "NJT-RVL": 0xF2A537,
        "NJL-HBL": 0x008080, "NJL-NLR": 0x009AD1, "NJL-RL": 0x00008B,
        // SEPTA Metro and PATCO (colors from their data)
        "SMT-L1": 0x0097D6, "SMT-B1": 0xF26100, "SMT-B2": 0xF26100, "SMT-B3": 0xF26100, "SMT-M1": 0x5F249F,
        "SMT-T1": 0x5A960A, "SMT-T2": 0x5A960A, "SMT-T3": 0x5A960A, "SMT-T4": 0x5A960A, "SMT-T5": 0x5A960A,
        "SMT-G1": 0xFFD700, "SMT-D1": 0xDC2E6B, "SMT-D2": 0xDC2E6B,
        "PAT-PATCO": 0xBC0035,
        // CTrail Hartford Line (red from official data)
        "CTR-HL": 0xEA0D2A,
        // CTrail Shore Line East (in Amtrak's package; see FerryFeed.shoreLineEast)
        FerryFeed.shoreLineEastRoute: UInt32(FerryFeed.shoreLineEast.color, radix: 16) ?? 0x00537E,
    ]
    /// The few lines that use dark text in official data (light backgrounds)
    static let darkText: Set<String> = ["LIRR-HEM", "LIRR-MTK", "LIRR-WH",
                                        "NJT-MBL", "NJT-PJL", "NJT-GLA", "NJT-MRL", "NJT-RVL", "SMT-G1"]

    static func color(_ route: String) -> Color {
        // Every Amtrak line uses Amtrak's dark blue (Shore Line East, CTrail's, has its own above); every SEPTA Regional Rail line
        // SEPTA's gray blue (from its data)
        let v = colors[route] ?? (route.hasPrefix("AMK-") || route.hasPrefix("AMJ-") ? 0x00537E
                                  : route.hasPrefix("SRR-") ? 0x4F758B
                                  : route.hasPrefix("NJB-") ? (UInt32(RegionalBusFeed.color(route: route), radix: 16) ?? 0x1A4B9B) : 0x0039A6)
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Ferry route badge: boat-shaped rounded tag in the route's official color (e.g. East River teal, Staten Island Ferry orange).
/// NY Waterway shows "NYW", Seastreak "SEA", Statue of Liberty ferry "SOL" (each operator is merged into one route; routes are told apart by destination).
struct FerryRouteBadge: View {
    var route: String
    var size: CGFloat = 22

    var body: some View {
        let label = FerryFeed.badge(route)
        Text(label)
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(Self.textColor(route))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size * 0.2)
            .frame(minWidth: size, minHeight: size * 0.82)
            .background(Capsule().fill(Self.color(route)))
            .accessibilityLabel(Text(FerryFeed.routeName(route)))
    }

    /// Colors from NYC Ferry, Staten Island Ferry and Seastreak official data; NY Waterway routes each have a different color,
    /// so the merged route uses a fixed red (same as the map).
    static func color(_ route: String) -> Color {
        switch route {
        case "NYF-AS": return Color(red: 1.0, green: 0.42, blue: 0.0)
        case "NYF-ER": return Color(red: 0.0, green: 0.51, blue: 0.61)
        case "NYF-RS": return Color(red: 0.31, green: 0.0, blue: 0.56)
        case "NYF-SB": return Color(red: 1.0, green: 0.82, blue: 0.0)
        case "NYF-SG": return Color(red: 0.82, green: 0.0, blue: 0.44)
        case "SIF": return Color(red: 1.0, green: 0.51, blue: 0.19)
        case "NYW": return Color(red: 0.78, green: 0.06, blue: 0.18)   // C8102E
        case "SST": return Color(red: 0.0, green: 0.19, blue: 0.40)    // 013067 (color from Seastreak official data)
        case "SOL": return Color(red: 0.18, green: 0.55, blue: 0.34)   // 2E8B57 (Statue of Liberty copper green; the data has no color)
        default: return Color(red: 0.0, green: 0.47, blue: 0.78)
        }
    }

    /// The yellow and orange ones use black text (white text is hard to read on orange)
    static func textColor(_ route: String) -> Color {
        ["NYF-SB", "NYF-AS", "SIF"].contains(route) ? .black : .white
    }
}

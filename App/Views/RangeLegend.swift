import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// Legend above the station list, one line: ◎ main range and ◌ extended range walks and the arrival window,
/// then the button to extend the range for now at the end of the line. Clicking the line shows the four full lines (main and extended
/// range, search radius, arrival window) in a small popover; screen readers read those four. While the range is extended for now,
/// the line says by how much.
/// Not shown on standby (the station list isn't either).
struct RangeLegend: View {
    @EnvironmentObject var transit: TransitModel
    @State private var showDetails = false
    @State private var hovering = false

    var body: some View {
        let l = transit.l10n
        let s = transit.effectiveSettings.sanitized()
        HStack(spacing: 6) {
            Button { showDetails.toggle() } label: {
                summary(l, s)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            // The tooltip only names the line (the system draws tooltips and can't lay out a list): the four lines are in the popover
            .help(l.t("Search range"))
            .accessibilityLabel(Text(Self.details(l, s, transit: transit).joined(separator: ". ")))
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                // A popover doesn't take the window's language and direction by itself
                RangeDetails(lines: Self.details(l, s, transit: transit))
                    .environment(\.locale, transit.language.locale)
                    .environment(\.layoutDirection, transit.layoutDirection)
            }
            Spacer(minLength: 0)
            TempRangeMenu(compact: true)
                .fixedSize()
        }
        .font(.scaled(.caption))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A plain gray line, without a box: the boxes above it are buttons and the place switch, and four gray boxes in a row ran
        // together. A thin line under it ends the group above the station list (only drawn: the row's height stays the same)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.stationSeparator)
                .frame(height: 1)
                .offset(y: 3)
                .accessibilityHidden(true)
        }
        .padding(.bottom, 4)
    }

    /// Main range walk, extended range walk and the arrival window, each after its icon ("15 min · 20 min · 2 hr"), with "+10 min for now" when extended for now.
    /// On one line when it all fits. When the tag for now doesn't fit on it, the tag goes on a line of its own under the rest: kept on the
    /// line, it left the numbers too little room and each was cut short on its own ("1…", "3…"). When the rest doesn't fit on one line
    /// either (the narrowest sidebar, larger text, a long translation), the arrival window goes on the next line, and when even the two
    /// walks don't fit side by side, each piece gets a line of its own. A piece ("15 min") is never split: the first of these that fits
    private func summary(_ l: UIText, _ s: CatchSettings) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                walks(l, s)
                extraTag(l)
                window(l, s)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    walks(l, s)
                    window(l, s)
                }
                extraTag(l)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    walks(l, s)
                }
                HStack(spacing: 4) {
                    arrivalWindow(l, s)
                }
                extraTag(l)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    primaryWalk(l, s)
                }
                HStack(spacing: 4) {
                    extendedWalk(l, s)
                }
                HStack(spacing: 4) {
                    arrivalWindow(l, s)
                }
                extraTag(l)
            }
        }
    }

    @ViewBuilder private func walks(_ l: UIText, _ s: CatchSettings) -> some View {
        primaryWalk(l, s)
        Text("·")
        extendedWalk(l, s)
    }

    @ViewBuilder private func primaryWalk(_ l: UIText, _ s: CatchSettings) -> some View {
        Image(systemName: "circle.circle").accessibilityHidden(true)
        Text(l.minutes(s.primaryWalkSeconds))
    }

    @ViewBuilder private func extendedWalk(_ l: UIText, _ s: CatchSettings) -> some View {
        Image(systemName: "circle.dashed").accessibilityHidden(true)
        Text(l.minutes(s.extendedWalkSeconds))
    }

    @ViewBuilder private func extraTag(_ l: UIText) -> some View {
        if transit.tempExtraMinutes > 0 {
            Text(l.f("+%@ for now", l.minutes(transit.tempExtraMinutes * 60)))
                .font(.scaled(.caption2).weight(.medium))
                .padding(.horizontal, 4)
                .overlay(Capsule().stroke(OutlineColor(), lineWidth: 1))
                .fixedSize()
        }
    }

    /// The arrival window after the walks on their line
    @ViewBuilder private func window(_ l: UIText, _ s: CatchSettings) -> some View {
        Text("·")
        arrivalWindow(l, s)
    }

    @ViewBuilder private func arrivalWindow(_ l: UIText, _ s: CatchSettings) -> some View {
        Image(systemName: "clock").accessibilityHidden(true)
        Text(l.duration(s.arrivalWindowSeconds))
    }

    /// The words on the line. The sidebar makes the row new when they change: they decide how many lines it takes
    @MainActor static func words(of transit: TransitModel) -> [String] {
        let l = transit.l10n
        let s = transit.effectiveSettings.sanitized()
        let extra = transit.tempExtraMinutes > 0 ? l.f("+%@ for now", l.minutes(transit.tempExtraMinutes * 60)) : ""
        return [l.minutes(s.primaryWalkSeconds), l.minutes(s.extendedWalkSeconds), l.duration(s.arrivalWindowSeconds), extra]
    }

    /// The legend's four full lines, for the popover, the hover tip and screen readers
    @MainActor static func details(_ l: UIText, _ s: CatchSettings, transit: TransitModel) -> [String] {
        var extended = l.f("Extended: %@ walk", l.minutes(s.extendedWalkSeconds))
        if transit.tempExtraMinutes > 0 { extended += " (" + l.f("+%@ for now", l.minutes(transit.tempExtraMinutes * 60)) + ")" }
        return [l.f("Primary: %@ walk", l.minutes(s.primaryWalkSeconds)),
                extended,
                l.f("Search radius: %@", l.radius(s.candidateRadiusMeters)),
                l.arrivalsWithin(transit.system, s.arrivalWindowSeconds)]
    }
}

/// The range legend's four full lines, in its popover
struct RangeDetails: View {
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let icons = ["circle.circle", "circle.dashed", "scope", "clock"]
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Label(line, systemImage: icons[min(i, icons.count - 1)])
            }
        }
        .labelStyle(IconColumnLabelStyle(widest: "scope"))
        .font(.scaled(.callout))
        .padding(12)
        .frame(maxWidth: 320 * TextScale.factor, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

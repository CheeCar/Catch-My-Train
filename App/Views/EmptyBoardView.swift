import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// When there are no stations to show (still locating, no starting place, no stations in range, etc.).
struct EmptyBoardView: View {
    @EnvironmentObject var transit: TransitModel
    var now: Date

    var body: some View {
        let l = transit.l10n
        // A reason other than no station nearby is the bold line itself (EmptyBoardReason.isTheBoldLine), not said again under it;
        // of several lines only the first is bold
        let ownLine = !transit.isLocating && !transit.needsPlace && transit.emptyBoardReason().isTheBoldLine
        let reason = EmptyBoardReason.boldLine(of: transit.emptyStateText())
        VStack(alignment: .leading, spacing: 8) {
            BusKeyPrompt().padding(.bottom, 8)
            Text(transit.isLocating ? l.t("Finding your location…")
                 : transit.needsPlace ? transit.missingPlaceText
                 : ownLine ? reason.bold
                 : l.pick(transit.system, train: l.t("No trains worth catching nearby"), bus: l.t("No buses worth catching nearby"),
                          ferry: l.t("No ferries worth catching nearby")))
                .font(.scaled(.headline))
            Group {
                if transit.isLocating {
                    StatusBanner(now: now)
                } else if ownLine {
                    if let rest = reason.rest { Text(rest) }
                } else {
                    // Same explanations as the menu bar panel (see TransitModel.emptyStateText)
                    Text(transit.emptyStateText())
                }
            }
            .foregroundStyle(.secondary)
            // A next step to click for each reason that has one
            if !transit.isLocating {
                EmptyBoardButtons(actions: transit.emptyBoardReason().actions)
                    .padding(.top, 4)
            }
            BoardFooter(board: transit.board(at: now), now: now)
                .padding(.top, 10)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The empty page's buttons (EmptyBoardAction), side by side and the same width; one under the other, still the
/// same width, when they don't fit side by side. Nothing when there is no next step.
struct EmptyBoardButtons: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var actions: [EmptyBoardAction]

    var body: some View {
        let l = transit.l10n
        if !actions.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons(l) }
                    .fixedSize()
                VStack(alignment: .leading, spacing: 6) { buttons(l) }
                    .fixedSize()
            }
        }
    }

    private func buttons(_ l: UIText) -> some View {
        ForEach(actions, id: \.self) { action in
            button(action, l)
                .appButtonStyle()
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func button(_ action: EmptyBoardAction, _ l: UIText) -> some View {
        switch action {
        case .extendRange:
            TempRangeMenu()
        case .choosePlace:
            Button(l.t("Choose a Place…")) { PlacePickerWindow.open(with: openWindow, transit: transit) }
        case .openSettings, .rangeSettings:
            // At the place the sentence names (SettingsJump)
            Button(l.t("Settings…")) {
                SettingsJump.to(action == .rangeSettings ? .searchRange : .privacy)
                NSApp.activate()
                openSettings()
            }
        case .refresh:
            Button(l.t("Refresh")) { transit.refresh() }
        case .start:
            Button(l.t("Start")) { transit.start() }
        case .showServiceArea:
            Button(l.t("Service Area")) { MapWindow.open(with: openWindow, showingServiceArea: true) }
        }
    }
}

/// Temporarily extend the walking range (without changing settings): click to pick +5 / +10 / +15 / +20 minutes; back to normal
/// automatically on standby or when the app quits. In the main window it sits in one place, under the range legend in the sidebar
/// (RangeLegend), next to the ranges it changes; the Transit menu at the top of the screen has the same choices.
struct TempRangeMenu: View {
    @EnvironmentObject var transit: TransitModel
    /// Only the icon and the small arrow (the sidebar's one-line legend); the words are in the hover tip and for screen readers
    var compact = false
    @State private var hovering = false

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        let l = transit.l10n
        let extra = transit.tempExtraMinutes
        let title = menuTitle(l, extra: extra)
        // Draw the button look ourselves (.button + .plain, with SmallBezel on the label): the system menu button ignores the app's
        // Text size. Only as wide as its words, at the start of the legend box; a long text is truncated at the box's width rather than
        // widening the sidebar (Italian etc.), and hovering shows all of it.
        Menu {
            // The menu's own check mark on the one in use, as in the line filter
            ForEach(TransitModel.tempExtraChoices, id: \.self) { m in
                Toggle(l.f("+%@ for now", l.minutes(m * 60)), isOn: .afterViewUpdate(get: { transit.tempExtraMinutes == m }, set: { _ in
                    transit.tempExtraMinutes = m
                }))
            }
            Divider()
            Button(l.t("Back to Normal Range")) { transit.tempExtraMinutes = 0 }
                .disabled(extra == 0)
            Text(l.t("Settings stay the same. Goes back to normal on standby."))
        } label: {
            HStack(spacing: 4) {
                // Plus: it adds minutes to the range (the two diagonal arrows mean "larger map" in the place picker)
                Image(systemName: "plus.circle")
                if !compact {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // The small arrow says that it opens a list of choices
                Image(systemName: "chevron.down")
                    .font(.scaled(.caption2).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.scaled(.caption))
            // Not usable on standby, so gray (on standby the legend and this button aren't shown anyway)
            .foregroundStyle(transit.isActive ? Color.primary : Color.secondary)
            .padding(.vertical, 1)
            .modifier(SmallBezel(hovering: hovering && transit.isActive))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!transit.isActive)
        // Only the button darkens on hover, not the empty space after it
        .onHover { hovering = $0 }
        .help(title + "\n" + l.t("Temporarily include stations farther away"))
        .accessibilityLabel(title)
        .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
    }
}

extension TempRangeMenu {
    /// Text on the menu button (when truncated, hover shows the full text)
    func menuTitle(_ l: UIText, extra: Double) -> String {
        extra > 0 ? l.f("Range extended by %@ for now", l.minutes(extra * 60)) : l.t("Extend Range for Now")
    }
}

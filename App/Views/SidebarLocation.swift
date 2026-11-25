import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// The place in use in the sidebar: with the current location, the place name from location lookup and "Change"; with a chosen
/// place, that place and "Choose a New Place". Both buttons open the place picker and look the same (SmallBezelButtonStyle).
/// One line when the whole name and the button fit side by side, the button on the end side. When they don't (a narrow sidebar, a larger
/// text size, a long name), the button moves under the name, still on the end side, instead of squeezing the name to a few letters.
/// A name too long even for a line of its own takes two lines, and only then is truncated at the end; hovering shows it whole.
struct LocationPlaceRow: View {
    @EnvironmentObject var transit: TransitModel
    @Binding var showPlacePicker: Bool

    /// What the row shows. The sidebar makes a new row whenever it changes, so the row's height follows (see its use there)
    struct Content: Hashable {
        var name: String
        var systemImage: String
        var button: String
        /// A line under them: how approximate the current position is (nil: none)
        var note: String? = nil
    }

    @MainActor static func content(of transit: TransitModel) -> Content {
        let l = transit.l10n
        // The button is there also while the location is being found or has failed
        let button = transit.locationMode == .manual ? l.t("Choose a New Place") : l.t("Change")
        // nil whenever the position isn't used or is exact enough
        let note = transit.locationAccuracyNote
        if transit.needsPlace {
            // No place was ever chosen and there is no position: no name to show, and the button chooses the first place
            return Content(name: transit.missingPlaceText, systemImage: transit.missingPlaceSymbol, button: l.t("Choose a Place…"))
        } else if transit.locationTooApproximate {
            // The position is too far off to use: the page on the right and the station list say so, with a button to choose a place
            return Content(name: l.t("Current location"), systemImage: "location.slash", button: button)
        } else if transit.locationMode == .manual {
            return Content(name: transit.place.name, systemImage: "mappin", button: button, note: note)
        } else if let origin = transit.origin, origin.kind == .demoCurrent {
            // Demo mode's current location: Times Square
            return Content(name: origin.name, systemImage: "location.fill", button: button, note: note)
        } else if transit.origin?.kind == .manualFallback {
            return Content(name: transit.place.name, systemImage: "location.slash", button: button)
        } else if transit.origin == nil {
            // Nothing is located on standby, so don't say it's being found
            return Content(name: transit.isActive ? l.t("Finding your location…") : l.t("Current location"), systemImage: "location", button: button)
        } else {
            return Content(name: transit.currentPlaceName ?? l.t("Current location"), systemImage: "location.fill", button: button,
                           note: note)
        }
    }

    var body: some View {
        let content = Self.content(of: transit)
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    place(content)
                    Spacer(minLength: 4)
                    button(content)
                }
                VStack(alignment: .leading, spacing: 4) {
                    place(content)
                    button(content)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            // Under the name and the button, wrapped as needed (the row is made new when it changes, see Content). Its own line
            // limit: the sidebar's rows keep text to one line unless told otherwise, and a longer translation was cut off
            if let note = content.note {
                Text(note)
                    .foregroundStyle(.secondary)
                    .lineLimit(SidebarText.sentenceLines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.scaled(.caption))
    }

    /// The sidebar's own label, so its icon looks as it does in the sidebar's other labels. On two lines, the icon goes beside
    /// the first: the name's middle is taken to be its first line's, which for a name on one line is its own middle, as before
    private func place(_ content: Content) -> some View {
        Label {
            Text(content.name)
                .alignmentGuide(VerticalAlignment.center) { d in
                    d.height / 2 - (d[.lastTextBaseline] - d[.firstTextBaseline]) / 2
                }
        } icon: {
            Image(systemName: content.systemImage)
        }
        .lineLimit(2)
        .truncationMode(.tail)
        .foregroundStyle(.secondary)
        .help(content.name)
    }

    private func button(_ content: Content) -> some View {
        Button(content.button) { showPlacePicker = true }
            .buttonStyle(SmallBezelButtonStyle())
            .lineLimit(1)
            .fixedSize()
    }
}

/// The two-segment "My current location / A place I choose" toggle in the sidebar.
/// Looks like the system segmented control (selected segment is white on blue, sliding over when the choice changes), but it never widens
/// the sidebar: when the sidebar is narrow, the text larger or a translation long, the text shrinks a little, and when the two segments
/// still don't fit side by side they go one above the other, each the full width, with the blue moving up and down between them.
struct LocationModeSwitch: View {
    var selection: LocationMode
    var l: UIText
    /// "Use my location" turned off in Settings: "My current location" is grayed out and can't be selected (a click blinks the note under it)
    var currentOff = false
    var choose: (LocationMode) -> Void
    @Namespace private var space
    /// Clicks on the grayed-out "My current location" (see LocationOffNote)
    @State private var offClicks = 0

    /// How far a segment's text shrinks before the segments go one above the other (no smaller than 10 pt), and the room around it
    /// that doesn't shrink (its padding on both sides)
    static let shrink: CGFloat = 0.85
    static let inset: CGFloat = 8

    /// The words of the switch, and of the note under it when there is one. The sidebar makes the row new when they change: they
    /// decide how tall it is (a list row's height doesn't follow its content). The choice isn't among them: it changes no size
    static func words(_ l: UIText, currentOff: Bool) -> [String] {
        [l.t("My current location"), l.t("A place I choose"), currentOff ? l.t("Location is off in Settings → Privacy.") : ""]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Side by side when each segment's text fits its half, shrunk if need be; otherwise one above the other. The blue
            // (segmentThumb) follows the chosen segment wherever it is
            SidebarWindowPairLayout(spacing: 2, shrink: Self.shrink, inset: Self.inset) {
                segment(l.t("My current location"), mode: .current)
                segment(l.t("A place I choose"), mode: .manual)
            }
            .segmentThumb(selection, in: space, cornerRadius: 5)
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
            .frame(minWidth: 0, maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(l.t("Walk from"))
            // Why "My current location" is grayed out, written where it shows, not only in its hover text.
            // A click on the grayed-out segment blinks this line: it says why nothing happened
            if currentOff {
                LocationOffNote(l: l, blink: offClicks)
            }
        }
    }

    private func segment(_ title: String, mode: LocationMode) -> some View {
        let on = selection == mode
        let off = mode == .current && currentOff
        return Button {
            if off { offClicks &+= 1 } else if !on { choose(mode) }
        } label: {
            // As wide as in semibold whichever is chosen: being chosen doesn't widen a segment, so whether the two fit side by side
            // doesn't change with the choice (the row's height wouldn't follow)
            ZStack {
                Text(title).fontWeight(.semibold).hidden().accessibilityHidden(true)
                Text(title).fontWeight(on ? .semibold : .regular)
            }
            .font(.scaled(.callout))
            // One line of fixed height: a long translation shrinks a little (to 85% at most, text no smaller than 10 pt), and when
            // that isn't enough the segments go one above the other. Truncated only when a segment doesn't fit even the whole width;
            // hover to see the full text then
            .lineLimit(1)
            .minimumScaleFactor(Self.shrink)
            .truncationMode(.tail)
            .foregroundStyle(on ? Color.white : off ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .padding(.vertical, 3)
            .padding(.horizontal, Self.inset / 2)
            .segmentSlot(mode, in: space)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(off ? l.t("Location is off in Settings → Privacy.") : title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

import AppKit
import CatchText
import SwiftUI
import TransitCore

/// The menu bar panel's bottom row: six buttons as wide as each other, each an icon with its short name under it. From the start:
/// the main window ("Departures"), Plan a Trip, the map, Refresh, Settings and More (the menu bar icon's right-click menu, where
/// Quit is: no button here quits at one click). A name takes up to two lines. When the names are counted to take two, all six
/// keep that height, however full the panel is; a name of several words takes its second line whenever it needs it, whatever the
/// count says. In a language where one of the six names can't be shown whole that way, the row shows the icons alone, all six
/// alike. Hovering shows a button's full name, and assistive tools read the full name ("Open Catch My Train", "Subway map").
struct PanelBottomBar: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Closes the panel: it goes away when one of its buttons opens a window, leaving only that window
    @Environment(\.dismiss) private var dismiss
    /// The More button's place on screen, for its menu (an empty view behind it)
    @State private var moreAnchor = MenuAnchor.Holder()

    var body: some View {
        let l = transit.l10n
        let names = Self.names(l)
        let nameLines = Self.nameLines(names, rowWidth: Self.rowWidth(for: transit.textSize))
        HStack(alignment: .top, spacing: 0) {
            PanelBarButton(name: names[0], fullName: l.t("Open Catch My Train"), systemImage: "macwindow", nameLines: nameLines) {
                dismiss()
                MainWindow.open(with: openWindow)
            }
            PanelBarButton(name: names[1], fullName: names[1], systemImage: "magnifyingglass", nameLines: nameLines) {
                dismiss()
                PlannerWindow.open(with: openWindow)
            }
            // The map follows the transit mode, and its full name says which ("Subway map", "Bus map")
            PanelBarButton(name: names[2], fullName: StationSidebar.mapName(transit.system, l), systemImage: "map", nameLines: nameLines) {
                dismiss()
                MapWindow.open(with: openWindow)
            }
            PanelBarButton(name: names[3], fullName: names[3], systemImage: "arrow.clockwise", nameLines: nameLines) {
                transit.refresh()
            }
            .disabled(!transit.isActive)
            PanelBarButton(name: names[4], fullName: names[4], systemImage: "gearshape", nameLines: nameLines) {
                dismiss()
                NSApp.activate()
                openSettings()
            }
            // Not a power button that quits at once: the right-click menu, where Quit is the last item
            PanelBarButton(name: names[5], fullName: names[5], systemImage: "ellipsis.circle", nameLines: nameLines) {
                StatusItemMenu.shared.popUp(below: moreAnchor.view)
            }
            .background(MenuAnchor(holder: moreAnchor))
        }
    }

    /// The six buttons' short names, from the start of the row
    static func names(_ l: UIText) -> [String] {
        [l.t("Departures"), l.t("Plan a Trip"), l.t("Map"), l.t("Refresh"), l.t("Settings"), l.t("More")]
    }

    /// The row's width at a text size: the panel's, less the room around its content
    static func rowWidth(for size: AppTextSize) -> CGFloat {
        MenuBarPanel.width(for: size) - 2 * MenuBarPanel.padding
    }

    /// The lines the names take under their icons when the row is this wide: 1, or 2 when one of them needs two. Nil when a
    /// name can't be shown whole on two lines: the row then shows its icons alone. Measured in the font the names are drawn in
    /// (LabelFit). A name may shrink a little to fit (PanelBarButton.smallestScale), so the room counted is that much wider,
    /// less a point for rounding
    static func nameLines(_ names: [String], rowWidth: CGFloat) -> Int? {
        guard !names.isEmpty else { return nil }
        let font = nameFont
        let room = nameRoom(rowWidth: rowWidth, names: names.count).counted
        var most = 1
        for name in names {
            let pieces = LabelFit.pieces(of: name) { countedWidth($0, font: font) }
            guard let lines = LabelFit.lines(pieces, width: room), lines <= 2 else { return nil }
            most = max(most, lines)
        }
        return most
    }

    /// The font the names are counted in: the one they are drawn in at the text size in use
    private static var nameFont: NSFont {
        NSFont.systemFont(ofSize: PanelBarButton.nameSize * TextScale.factor)
    }

    /// A text's width as nameLines counts it. A space counts as wide as it is between two words: measured alone it can come
    /// out as nothing (it did when the app was opened in a right-to-left language), and a name of several words was then
    /// counted narrower than it is drawn
    private static func countedWidth(_ text: String, font: NSFont) -> Double {
        text == " " ? spaceBetweenLetters(font) : measuredWidth(text, font: font)
    }

    /// A text's width on one line in this font
    private static func measuredWidth(_ text: String, font: NSFont) -> Double {
        Double((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// A space's width where a name has one: between two letters
    private static func spaceBetweenLetters(_ font: NSFont) -> Double {
        measuredWidth("n n", font: font) - measuredWidth("nn", font: font)
    }

    /// A name's column when the row is this wide, and the room nameLines counts for it there
    private static func nameRoom(rowWidth: CGFloat, names: Int) -> (column: Double, counted: Double) {
        let column = rowWidth / CGFloat(names) - 2 * PanelBarButton.sideRoom
        return (Double(column), Double(column / PanelBarButton.smallestScale) - 1)
    }
}


/// One button of the panel's bottom row: its icon, and under it its short name in small text when the row shows names (in the
/// middle, on as many lines as the row's names take). As wide as the row gives it, and all of that can be clicked
private struct PanelBarButton: View {
    /// The names' size in points at the standard text size (the caption size)
    static let nameSize: CGFloat = 10
    /// How far a name may shrink to fit its column
    static let smallestScale: CGFloat = 0.9
    /// Kept free at each side of a name, so the names of two buttons never touch
    static let sideRoom: CGFloat = 2

    var name: String
    var fullName: String
    var systemImage: String
    /// The lines the row's names take (PanelBottomBar.nameLines); nil: the icon alone
    var nameLines: Int?
    var action: () -> Void

    /// The name may go on two lines: it has more than one word, or is in a script written without spaces
    static func breaks(_ name: String) -> Bool {
        LabelFit.pieces(of: name) { _ in 0 }.count > 1
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                // The same height for every icon, so the names start on one line
                Image(systemName: systemImage)
                    .font(.scaled(.title3))
                    .frame(height: 18 * TextScale.factor)
                if let nameLines {
                    Text(name)
                        .font(.system(size: Self.nameSize * TextScale.factor))
                        // On a row counted as two lines, always as tall as two: a panel grown to its full height presses
                        // what gives way, and a name pressed onto one line was cut short. On a row counted as one line a
                        // name of several words may still take a second: the count is a measurement, and a name it took
                        // for a little narrower than it is drawn was cut short on its one line
                        .lineLimit(nameLines == 1 && !Self.breaks(name) ? 1 : 2, reservesSpace: nameLines == 2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(Self.smallestScale)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Self.sideRoom)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(fullName)
        .accessibilityLabel(Text(fullName))
    }
}

/// An empty view that tells where it is (for a menu popped up from a SwiftUI button). Never in the mouse's way
struct MenuAnchor: NSViewRepresentable {
    final class Holder {
        weak var view: NSView?
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}

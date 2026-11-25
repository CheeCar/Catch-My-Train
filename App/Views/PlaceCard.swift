import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// Where each favorite card sits in the two-column grid, in left-to-right coordinates. In right-to-left languages each row is reversed,
/// so the first favorite is at top right.
struct FavoriteGrid {
    static let space = "favoriteGrid"
    let count: Int
    let rightToLeft: Bool
    let rowHeight: CGFloat
    let spacing: CGFloat
    let width: CGFloat

    var cellWidth: CGFloat { max(0, (width - spacing) / 2) }

    /// Height of all the rows
    var height: CGFloat {
        let rows = (count + 1) / 2
        return CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * spacing
    }

    /// Top left of the picked-up card: under the pointer where it was grabbed, but kept within the grid
    func liftOrigin(pointer: CGPoint, grab: CGSize) -> CGPoint {
        CGPoint(x: min(max(pointer.x - grab.width, 0), max(width - cellWidth, 0)),
                y: min(max(pointer.y - grab.height, 0), max(height - rowHeight, 0)))
    }

    /// Top left of the card at this position in the favorites list
    func origin(of index: Int) -> CGPoint {
        let column = rightToLeft ? 1 - index % 2 : index % 2
        return CGPoint(x: CGFloat(column) * (cellWidth + spacing), y: CGFloat(index / 2) * (rowHeight + spacing))
    }

    /// The position in the favorites list for a point in the grid (the nearest card for a point in a gap, past the edges or in an empty cell)
    func index(at point: CGPoint) -> Int {
        guard count > 0 else { return 0 }
        let row = min(max(Int((point.y / (rowHeight + spacing)).rounded(.down)), 0), (count - 1) / 2)
        let column = point.x < width / 2 ? 0 : 1
        return min(row * 2 + (rightToLeft ? 1 - column : column), count - 1)
    }

    /// The cards in the order the grid shows them, row by row from the left. A right-to-left last row with one card has an empty left cell.
    func slots(_ places: [UserPlace]) -> [FavoriteSlot] {
        guard rightToLeft else { return places.map { .place($0) } }
        return stride(from: 0, to: places.count, by: 2).flatMap { i -> [FavoriteSlot] in
            [i + 1 < places.count ? .place(places[i + 1]) : .gap, .place(places[i])]
        }
    }
}

enum FavoriteSlot: Hashable {
    case place(UserPlace)
    case gap
}

/// A favorite card being dragged: where on the card it was grabbed, where its top left is now (grid coordinates),
/// and whether it is gliding into its place after being let go
struct FavoriteLift {
    let place: UserPlace
    let grab: CGSize
    var origin: CGPoint
    var settling = false
}

struct FavoritesWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A place card: the star in front, the name, a check on the place walking times are measured from now, and on a recent place × at
/// the end. The star is the one button for the favorites everywhere: on a favorite (filled) it removes it from the favorites, on a
/// recent place it adds it or removes it; × removes a recent place from the recent places. A favorite has no × (it would do what its
/// star does). A click selects the card, a double click uses its place. The selected card has the accent color behind it, drawn here
/// (so it doesn't depend on which part of the window has the keyboard focus). On hover the card darkens slightly and the × stands out
/// more. A name too long for one line is drawn one text style smaller on up to two lines, in the same height; the tooltip has it in
/// full.
struct PlaceCard: View {
    let place: UserPlace
    let isFavorite: Bool
    /// A card in the favorites grid (not in the recent places)
    var favoriteRow = false
    /// Favorites not full yet: an unstarred place can be starred (when full the star is grayed out, with an explanation)
    var canAddFavorite = true
    var inUse = false
    var selected = false
    let height: CGFloat
    let l: UIText
    /// A click on the card, with its click count (2: a double click)
    var click: (Int) -> Void = { _ in }
    var use: () -> Void = {}
    var toggleFavorite: () -> Void = {}
    var remove: () -> Void = {}
    /// In the favorites grid: move the card one place left or right on screen (nil: it can't go that way, the item is gray). Also in
    /// the right-click menu, the screen reader's actions and ⌥⌘← ⌥⌘→, for whoever can't drag
    var moveLeft: (() -> Void)?
    var moveRight: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StarButton(isFavorite: isFavorite, enabled: isFavorite || canAddFavorite, help: starHelp, label: starHelp,
                       onAccent: selected, action: toggleFavorite)
            // The window's body text on one line when it fits, the check of the place in use after it. Otherwise one text style
            // smaller (callout), on up to two lines that fit in the card's height at every text size (the card never grows), cut short
            // only at the second line's end; the check then goes before the name and wraps with it, so it takes no width of its own
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    nameButton(Text(place.name).lineLimit(1))
                    if inUse {
                        Image(systemName: "checkmark")
                            .font(.scaled(.caption).weight(.bold))
                            .foregroundStyle(selected ? Color.white : Color.accentColor)
                            .help(l.f("Walking from %@", place.name))
                            .accessibilityLabel(Text(l.f("Walking from %@", place.name)))
                    }
                }
                nameButton((inUse ? inlineCheck + Text(place.name) : Text(place.name))
                    .font(.scaled(.callout))
                    .lineLimit(2)
                    .truncationMode(.tail), saysWalkingFrom: inUse)
            }
            if !favoriteRow {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill((selected ? Color.white : Color.primary).opacity(hovering ? 0.15 : 0)))
                        // Still looks like an 18 pt circle, but the clickable area is 22 pt
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .opacity(hovering || selected ? 1 : 0.5)
                .help(l.t("Remove"))
                .accessibilityLabel(Text(l.t("Remove")))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.09 : 0.05)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { click(Self.clickCount) }
        .onHover { hovering = $0 }
        // The place in use: its name with what it is for (the check before a wrapped name has no tooltip of its own)
        .help(inUse ? l.f("Walking from %@", place.name) : place.name)
        .contextMenu {
            Button(l.t("Use"), action: use)
            if favoriteRow {
                // In the favorites grid a separate "Remove" would do the same: both take the place out of the favorites
                Button(l.t("Remove from favorites"), action: remove)
                Divider()
                // The keys work while a card is selected (PlacePicker: the cards' onKeyPress); shown here so they can be found
                Button(l.t("Move Left")) { moveLeft?() }
                    .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
                    .disabled(moveLeft == nil)
                Button(l.t("Move Right")) { moveRight?() }
                    .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
                    .disabled(moveRight == nil)
            } else {
                Button(isFavorite ? l.t("Remove from favorites") : l.t("Add to favorites"), action: toggleFavorite)
                    .disabled(!isFavorite && !canAddFavorite)
                Divider()
                Button(l.t("Remove"), role: .destructive, action: remove)
            }
        }
    }

    /// The name is a button: the keyboard (Tab here and press Space) and screen readers can select this place too. Screen readers
    /// get the whole name, whichever way it is shown, and "Walking from" when the check is part of the name's text
    private func nameButton(_ name: some View, saysWalkingFrom: Bool = false) -> some View {
        Button {
            click(Self.clickCount)
        } label: {
            name
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(place.name))
        .accessibilityValue(saysWalkingFrom ? l.f("Walking from %@", place.name) : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        // A favorite's card: Move Left and Move Right among the screen reader's actions (VO-Command-Space), as in its menu
        .accessibilityActions {
            if let moveLeft {
                Button(l.t("Move Left"), action: moveLeft)
            }
            if let moveRight {
                Button(l.t("Move Right"), action: moveRight)
            }
        }
    }

    /// The check before a wrapped name (the place in use), with a no-break space after it so it stays with the name's first word
    private var inlineCheck: Text {
        Text(Image(systemName: "checkmark"))
            .font(.scaled(.caption).weight(.bold))
            .foregroundStyle(selected ? Color.white : Color.accentColor)
            + Text("\u{00A0}")
    }

    private var starHelp: String {
        isFavorite ? l.t("Remove from favorites") : canAddFavorite ? l.t("Add to favorites")
            : l.f("Favorites are full (%@). Remove one to add another.", "\(SharedStore.maxFavorites)")
    }

    /// The click count of the mouse click being handled (2: a double click); 1 for anything else, such as Space on the keyboard
    @MainActor private static var clickCount: Int {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp else { return 1 }
        return event.clickCount
    }
}

/// The favorite star: filled (yellow) for a favorite, an outline otherwise. In the place picker and on the transit map's cards
struct StarButton: View {
    let isFavorite: Bool
    let enabled: Bool
    let help: String
    let label: String
    /// On a selected card (the accent color behind it): the outline is white
    var onAccent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                // On the accent color a filled white star (the gold would not stand out on blue); its shape still says it is a favorite
                .foregroundStyle(onAccent ? Color.white : isFavorite ? Color.favoriteStar : Color.secondary)
                .frame(minWidth: 16)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(Text(label))
    }
}

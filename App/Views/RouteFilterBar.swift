import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// Route filter (like the MTA app): "All" plus one round badge per route, multi-select.
struct RouteFilterBar: View {
    var routes: [String]
    @Binding var filter: Set<String>
    var l: UIText

    /// How far the content has scrolled left, the total content width, and the visible width (for drawing our own scroll bar)
    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var viewWidth: CGFloat = 0
    @State private var hovering = false
    /// Mouse is over the scroll bar itself (it overlays the routes and blocks hover on that row, so it's tracked separately)
    @State private var barHovering = false
    @State private var dragging = false
    /// Wait a moment after the mouse leaves before hiding the scroll bar, so moving from routes to the scroll bar doesn't make it flash away
    @State private var hideTask: DispatchWorkItem?
    @State private var showBar = false
    /// Thumb position while dragging (0 to 1)
    @State private var dragFraction: CGFloat = 0
    /// The NSScrollView behind the SwiftUI horizontal scroll area: when dragging the scroll bar, scroll it directly to a given offset
    @State private var scroller = EnclosingScrollView()
    @Environment(\.layoutDirection) private var direction

    private static let space = "routeFilterBar"
    private static let allTag = "__all"

    var body: some View {
        // Too many routes for one row: a menu at the end lists them all, with checkmarks, so a line can be found and chosen without
        // scrolling. With some chosen, it shows how many
        HStack(alignment: .top, spacing: 6) {
            routeRow
            if contentWidth > viewWidth + 1, viewWidth > 0 {
                RouteFilterMenu(routes: routes, filter: $filter, l: l)
                    .padding(.top, 2)
            }
        }
    }

    private var routeRow: some View {
        // When there are too many routes for one row, hovering the row shows a horizontal scroll bar below that can be dragged
        // (the system scroll bar doesn't appear until you scroll, so you can't tell there's more to the right). Hidden when everything fits.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        filter = []
                    } label: {
                        // As tall as the route badges beside it (24 pt and the 3 pt ring margin on each side)
                        Text(l.t("All lines"))
                            .font(.scaled(.callout).weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Capsule().fill(filter.isEmpty ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter.isEmpty ? .isSelected : [])
                    .id(Self.allTag)
                    ForEach(routes, id: \.self) { route in
                        let on = filter.contains(route)
                        Button {
                            if on { filter.remove(route) } else { filter.insert(route) }
                        } label: {
                            RouteBadge(route: route, size: 24)
                                .padding(3)
                                // The ring has the badge's shape (a circle only around the round ones)
                                .background(RouteBadge.outline(of: route, size: 24, margin: 3)
                                    .stroke(Color.accentColor, lineWidth: on ? 2 : 0))
                                // Lines not chosen turn gray instead of fading away: still readable, their letters at full contrast
                                // (a faded badge was under 3:1)
                                .saturation(filter.isEmpty || on ? 1 : 0)
                        }
                        .buttonStyle(.plain)
                        .help(FerryFeed.spokenRouteName(route))
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .id(route)
                    }
                }
                // Several lines can be chosen at once, so nothing slides here: the rings and dimming fade, as quickly as the other switches move
                .animation(Motion.segments, value: filter)
                .padding(.top, 2)
                // Leave room for the scroll bar so it doesn't cover the route badges
                .padding(.bottom, 10)
                .background(GeometryReader { g in
                    Color.clear.preference(key: RouteBarMetrics.self,
                                           value: [g.frame(in: .named(Self.space)).minX, g.size.width])
                })
                // When dragging the scroll bar, scroll directly by offset (smooth, bit by bit), with no invisible position markers to scroll to
                // (one every 4 points would mean hundreds of them with many routes)
                .background(EnclosingScrollViewFinder(holder: scroller))
            }
            .coordinateSpace(name: Self.space)
            // More lines beyond the end of the row: it fades out over its last points there, so a line cut in half doesn't look
            // chopped off beside the menu button (most of all at large text). Nothing fades once the row is scrolled to that end.
            // The fading piece is at the row's end in both layout directions (the stack puts it there), clear at the outer edge.
            // Leading to trailing: the system mirrors a gradient right to left by itself (turning it by hand as well turned it
            // back, and the fade sat a badge in from the end with a hard edge beside the menu button)
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: moreAtEnd ? 20 : 0)
                }
            }
            // Right to left, "All lines" is at the right end of the row, but the scroll area opens at its left end: when the routes
            // don't fit, "All lines" was cut off. Bring it into view when the row appears and when its routes or its width change
            .onAppear { revealAllLines(proxy) }
            .onChange(of: routes) { _, _ in revealAllLines(proxy) }
            .onChange(of: viewWidth) { _, _ in revealAllLines(proxy) }
            .background(GeometryReader { g in
                Color.clear.preference(key: RouteBarViewWidth.self, value: g.size.width)
            })
            // Store only when the size really changed: storing redraws this view, and the redraw reports the size again (a possible cause of the AttributeGraph warning)
            .onPreferenceChange(RouteBarMetrics.self) { m in
                guard m.count == 2 else { return }
                if abs(-m[0] - offset) > 0.5 { offset = -m[0] }
                if abs(m[1] - contentWidth) > 0.5 { contentWidth = m[1] }
            }
            .onPreferenceChange(RouteBarViewWidth.self) { w in
                if abs(w - viewWidth) > 0.5 { viewWidth = w }
            }
            .overlay(alignment: .bottomLeading) {
                if showBar, contentWidth > viewWidth + 1, viewWidth > 0 {
                    scrollBar
                        .onHover { barHovering = $0; updateBar() }
                }
            }
            // The route row and the scroll bar count as one area: stays visible while the mouse is over either part
            .onHover { hovering = $0; updateBar() }
            .animation(Motion.fade, value: showBar)
        }
    }

    /// Whether lines lie hidden beyond the end of the row, the menu button's side (left to right: the right end): the row fades out
    /// there (see routeRow's mask). Asked of the scroll area itself, whose numbers are the same in both layout directions; from the
    /// row's own numbers until it is found. Worked out when the row is drawn, which every scroll makes happen (it stores `offset`)
    private var moreAtEnd: Bool {
        guard viewWidth > 0, contentWidth > viewWidth + 1 else { return false }
        let rightToLeft = direction == .rightToLeft
        if let hidden = scroller.hidden { return rightToLeft ? hidden.left : hidden.right }
        return rightToLeft ? offset > 1 : offset + viewWidth < contentWidth - 1
    }

    /// Right to left only: scrolls just enough to show "All lines" in full (left to right, the row already opens there).
    /// Waits for the end of this layout pass, when the row has its final width.
    private func revealAllLines(_ proxy: ScrollViewProxy) {
        guard direction == .rightToLeft else { return }
        DispatchQueue.main.async { proxy.scrollTo(Self.allTag) }
    }

    /// Mouse over the routes or the scroll bar, or dragging: show right away; once none of these: hide after 0.6 seconds
    private func updateBar() {
        hideTask?.cancel()
        hideTask = nil
        if hovering || barHovering || dragging {
            if !showBar { showBar = true }
        } else if showBar {
            let task = DispatchWorkItem { showBar = false }
            hideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
        }
    }

    /// Custom horizontal scroll bar: its length shows the visible fraction, its position follows scrolling; press and drag to scroll the routes.
    private var scrollBar: some View {
        let track = viewWidth
        let thumb = max(30, track * track / contentWidth)
        let maxOffset = contentWidth - viewWidth
        // While dragging, the thumb follows the mouse without waiting for the scroll result (otherwise the two chase each other and jitter)
        let fraction = dragging ? dragFraction : min(max(offset / maxOffset, 0), 1)
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.15))
                .frame(width: track, height: 6)
            Capsule().fill(Color.secondary.opacity(dragging ? 0.75 : 0.5))
                .frame(width: thumb, height: 6)
                .offset(x: fraction * (track - thumb))
        }
        .frame(width: track, height: 10)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !dragging { dragging = true; updateBar() }
                // The pressed position maps to the offset to scroll to
                let f = min(max((value.location.x - thumb / 2) / max(track - thumb, 1), 0), 1)
                dragFraction = f
                scroller.scroll(toX: (f * maxOffset).rounded())
            }
            .onEnded { _ in dragging = false; updateBar() })
        .accessibilityHidden(true)
    }
}

/// All of a station's routes in a menu, each with a checkmark when chosen: the route filter's way to reach every line when they don't
/// fit in one row. Choosing one adds it to the filter or takes it out, like its badge; "All lines" clears the filter. The button shows how
/// many are chosen.
struct RouteFilterMenu: View {
    var routes: [String]
    @Binding var filter: Set<String>
    var l: UIText

    var body: some View {
        Menu {
            Button(l.t("All lines")) { filter = [] }
                .disabled(filter.isEmpty)
            Divider()
            // One switch per line, on when it's shown: the menu's own check mark (a check mark image in a Label isn't drawn in
            // Mac menus), and screen readers say which ones are on
            ForEach(routes, id: \.self) { route in
                Toggle(FerryFeed.spokenRouteName(route), isOn: .afterViewUpdate(get: { filter.contains(route) }, set: { on in
                    if on { filter.insert(route) } else { filter.remove(route) }
                }))
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                if !filter.isEmpty {
                    Text(l.number(Double(filter.count)))
                        .monospacedDigit()
                }
                Image(systemName: "chevron.down")
                    .font(.scaled(.caption2).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.scaled(.callout).weight(.semibold))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Capsule().fill(filter.isEmpty ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.25)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l.t("All lines"))
        .accessibilityLabel(Text(l.t("All lines")))
        .accessibilityValue(Text(filter.isEmpty ? "" : l.commaList(routes.filter(filter.contains).map(FerryFeed.spokenRouteName))))
    }
}

/// Remembers the NSScrollView behind the SwiftUI scroll area (weak reference, so it isn't kept after the window closes).
final class EnclosingScrollView {
    weak var view: NSScrollView?

    /// Whether content lies hidden beyond the left and the right end of what is in sight; nil before the scroll area is found
    var hidden: (left: Bool, right: Bool)? {
        guard let view, let document = view.documentView else { return nil }
        let clip = view.contentView.bounds
        return (left: clip.minX > 1, right: clip.maxX < document.frame.width - 1)
    }

    /// Scrolls horizontally to x (no animation; the thumb and routes move together)
    func scroll(toX x: CGFloat) {
        guard let view else { return }
        let clip = view.contentView
        guard abs(clip.bounds.origin.x - x) >= 0.5 else { return }
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        view.reflectScrolledClipView(clip)
    }
}

/// Placed in the scroll content's background; finds the enclosing NSScrollView and hands it to holder (also the setup window's).
struct EnclosingScrollViewFinder: NSViewRepresentable {
    var holder: EnclosingScrollView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Right after being added to a window there's no superview yet: look again once this layout pass ends
        DispatchQueue.main.async { [weak nsView] in
            if let scroll = nsView?.enclosingScrollView, holder.view !== scroll { holder.view = scroll }
        }
    }
}

private struct RouteBarMetrics: PreferenceKey {
    static let defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

private struct RouteBarViewWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

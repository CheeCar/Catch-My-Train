import AppKit
import os
import SwiftUI

/// Turns off the list's own selection highlight (the cards draw it, see SidebarCard) and keeps the station list from staying
/// scrolled past its end. When stations drop out of the list, or its rows are replaced for a new
/// order (see SidebarStationRow), the table gets shorter, and its scroll position could stay where it was: the rows then jumped up and
/// left an empty area underneath until the next scroll. Each time the table's frame changes, a list scrolled down with empty space under
/// its last row is scrolled back up (the log says when, so it can be seen how often that happens).
///
/// It also looks at the list a few times after it appears, and when another of the app's windows opens in front or closes (checkAll):
/// the list of a new install on standby doesn't change while its setup window is open, so nothing else would look at it again, and
/// its rows were seen staying under the title bar until that window closed.
struct SidebarScrollClamp: NSViewRepresentable {
    func makeNSView(context: Context) -> ClampView { ClampView() }
    func updateNSView(_ view: ClampView, context: Context) { view.attachSoon() }

    final class ClampView: NSView {
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        /// The lists that are in a window now (see checkAll)
        private static let live = NSHashTable<ClampView>.weakObjects()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachSoon()
            guard window != nil else { return }
            Self.live.add(self)
            for delay in [0.5, 1.5, 4.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated { self?.check("after \(delay) s") }
                }
            }
        }

        /// A moment later: the list's own scroll area may not be in the window yet
        func attachSoon() {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.attach() }
            }
        }

        /// Looks at every sidebar list that is in a window, now and once more a second later (when a window that opened in front has
        /// settled). `why` goes to the log
        static func checkAll(_ why: String) {
            for view in live.allObjects { view.check(why) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    for view in live.allObjects { view.check(why + ", a second later") }
                }
            }
        }

        /// Looks at the list outside a change of its table: finds it if that hasn't happened yet, puts it right when its rows stand
        /// in the wrong place, and logs where they stood (numbers only)
        func check(_ why: String) {
            guard window != nil else { return }
            attach()
            let before = state()
            let moved = clamp()
            AppLog.ui.notice("Sidebar list \(why, privacy: .public): \(before, privacy: .public)\(moved ? "; put right" : "", privacy: .public)")
        }

        /// The list's scroll area: in this window, the one with a table over the middle of this view (it sits behind the list)
        private func attach() {
            guard let window, let root = window.contentView else { return }
            if let current = scrollView, current.window === window { hideHighlight(); return }
            let mine = convert(bounds, to: nil)
            let middle = CGPoint(x: mine.midX, y: mine.midY)
            func scrollViews(in view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
            }
            guard let found = scrollViews(in: root).first(where: {
                $0.documentView is NSTableView && $0.convert($0.bounds, to: nil).contains(middle)
            }), let table = found.documentView else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            scrollView = found
            hideHighlight()
            table.postsFrameChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: table,
                                                              queue: .main) { [weak self] _ in
                // Once the table has finished this change
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { _ = self?.clamp() }
                }
            }
        }

        /// The station cards draw the selection themselves (SidebarCard): the table's own highlight would sit around the blue card,
        /// a little bigger or smaller. Set again after each update of the list, in case SwiftUI sets the style back
        private func hideHighlight() {
            guard let table = scrollView?.documentView as? NSTableView, table.selectionHighlightStyle != .none else { return }
            table.selectionHighlightStyle = .none
        }

        /// How many times the list was scrolled back
        static private(set) var scrolledBack = 0

        /// How far above its rows' start the list begins when it's at its top: the part of the scroll area under the title bar.
        /// Some macOS versions keep it in the clip view's top inset and others don't (the inset reads 0 there), so it's the larger of
        /// that inset and what the scroll area itself answers when asked for a place far above the top. Going by the inset alone,
        /// rows that had jumped up were brought back only as far as the window's top edge, under the title bar
        static func topInset(of clip: NSClipView, table: NSTableView) -> CGFloat {
            let far = NSRect(x: clip.bounds.minX, y: -1_000_000, width: clip.bounds.width, height: clip.bounds.height)
            let asked = -table.convert(clip.constrainBoundsRect(far), from: clip).minY
            // An answer that isn't a title bar's height (the scroll area didn't hold the place asked for inside its range) is left out
            return max(clip.contentInsets.top, (0...200).contains(asked) ? asked : 0)
        }

        /// Scrolled down with empty space under the last row: scrolls back up by that much (so the last row sits at the bottom),
        /// or to the top when all rows fit. Also when the scroll position is past the table's end. True when it scrolled
        @discardableResult
        private func clamp() -> Bool {
            // A table's top is its smallest y (it's flipped); the part under the footer is the clip view's bottom inset
            guard let found = scrollView, let table = found.documentView as? NSTableView, table.isFlipped,
                  table.numberOfRows > 0 else { return false }
            let clip = found.contentView
            let shown = table.convert(clip.bounds, from: clip)
            let down = shown.minY + Self.topInset(of: clip, table: table)
            let empty = shown.maxY - clip.contentInsets.bottom - table.rect(ofRow: table.numberOfRows - 1).maxY
            let past = abs(clip.constrainBoundsRect(clip.bounds).origin.y - clip.bounds.origin.y)
            let back = max(min(down, empty), past)
            guard back > 0.5 else { return false }
            var origin = clip.bounds.origin
            origin.y -= max(min(down, empty), 0)
            let inside = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
            AppLog.ui.notice("Sidebar list was \(Int(back.rounded()), privacy: .public) pt past its end; scrolled back")
            Self.scrolledBack += 1
            clip.scroll(to: inside.origin)
            found.reflectScrolledClipView(clip)
            return true
        }

        /// Where the list stands, for the log: numbers only. "covered" is how much of the scroll area the window says is under its
        /// title bar; "inset" the clip view's own top inset and "top" the one clamp goes by (topInset); "down" how far the rows are
        /// scrolled from that top; "rows" where the last row ends and "room" the height they have
        private func state() -> String {
            guard let found = scrollView, let table = found.documentView as? NSTableView, let window else { return "no list yet" }
            let clip = found.contentView
            let shown = table.convert(clip.bounds, from: clip)
            let top = Self.topInset(of: clip, table: table)
            let covered = found.convert(found.bounds, to: nil).maxY - window.contentLayoutRect.maxY
            let last = table.numberOfRows > 0 ? table.rect(ofRow: table.numberOfRows - 1).maxY : 0
            return "covered \(Int(covered.rounded())), inset \(Int(clip.contentInsets.top.rounded())), top \(Int(top.rounded())), "
                + "safe area \(Int(found.safeAreaInsets.top.rounded())), down \(Int((shown.minY + top).rounded())), "
                + "rows \(table.numberOfRows) to \(Int(last.rounded())), table \(Int(table.frame.height.rounded())), "
                + "room \(Int(clip.bounds.height.rounded())), key \(window.isKeyWindow)"
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

import AppKit
import SwiftUI
import TransitCore

/// Behind a list that scrolls inside another scrolling area: a scroll gesture that starts over the list while it is at its end
/// stays with the list (nothing moves) instead of moving the area around it (see InnerScroll). Without the list's own scroll
/// area found, every event goes through as before.
struct ScrollStaysInside: NSViewRepresentable {
    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ view: Catcher, context: Context) {}

    final class Catcher: NSView {
        private var monitor: Any?
        private var gesture = InnerScroll.Gesture()
        private weak var list: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Scroll events arrive on the main thread
                let dropped = MainActor.assumeIsolated { self?.drops(event) ?? false }
                return dropped ? nil : event
            }
        }

        private func drops(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, let list = scrollArea(), let content = list.documentView else { return false }
            // A new gesture: the fingers start moving, or one step of a mouse wheel (it has no phases)
            let starts = event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty)
            let over = visibleRect.contains(convert(event.locationInWindow, from: nil))
            let shown = list.documentVisibleRect
            let most = content.frame.height - shown.height
            let offset = content.isFlipped ? shown.minY - content.bounds.minY : content.bounds.maxY - shown.maxY
            return gesture.drops(starts: starts, over: over, offset: Double(offset), most: Double(most),
                                 delta: Double(event.scrollingDeltaY))
        }

        /// The list's own scroll area: the one in this window that covers this view (which sits right behind it)
        private func scrollArea() -> NSScrollView? {
            guard let window, let root = window.contentView else { return nil }
            if let list, list.window === window { return list }
            let mine = convert(bounds, to: nil)
            func scrollViews(in view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
            }
            list = scrollViews(in: root).first {
                let frame = $0.convert($0.bounds, to: nil)
                return abs(frame.minX - mine.minX) < 2 && abs(frame.maxX - mine.maxX) < 2
                    && abs(frame.minY - mine.minY) < 2 && abs(frame.maxY - mine.maxY) < 2
            }
            return list
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

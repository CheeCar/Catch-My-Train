import Foundation

/// A list that scrolls inside another scrolling area (the favorites box in the place picker's left column).
/// macOS gives a scroll gesture that starts while the list is already at its end to the area around it, so the whole column moved
/// under a pointer that was over the list. A gesture that starts over such a list stays with it instead: nothing moves.
/// A list that shows everything doesn't scroll, and gestures over it go to the area around it as before.
public enum InnerScroll {
    /// Whether a gesture that starts now would be passed on to the area around the list.
    /// - offset: how far the list is scrolled from its top
    /// - most: how far it can be scrolled (0 when everything fits)
    /// - delta: the gesture's first vertical step (positive = toward the list's top)
    public static func isAtItsEnd(offset: Double, most: Double, delta: Double) -> Bool {
        guard most > 1, delta != 0 else { return false }
        return delta > 0 ? offset <= 1 : offset >= most - 1
    }

    /// Follows the scroll events of one window and says which to drop. A gesture is decided when it starts, and what follows of
    /// it (also its coasting after the fingers lift) goes the same way
    public struct Gesture: Equatable, Sendable {
        private var dropping = false

        public init() {}

        /// One scroll event. `starts`: a new gesture begins with it (fingers start moving, or one step of a mouse wheel);
        /// `over`: the pointer is over the list. True = drop the event
        public mutating func drops(starts: Bool, over: Bool, offset: Double, most: Double, delta: Double) -> Bool {
            if starts { dropping = over && InnerScroll.isAtItsEnd(offset: offset, most: most, delta: delta) }
            return dropping
        }
    }
}

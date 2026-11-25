import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

// MARK: Hover text

/// The block the mouse is on in Plan a Trip and its hover text, shown at once (PlannerTipLayer): the system's tooltip comes only after
/// the mouse has stood still for a while. One for the window; every block reads it, so only the one under the mouse has the darker
/// edge and says where the text goes (PlannerTipSource)
final class PlannerHover: ObservableObject {
    struct Shown: Equatable {
        var id: String
        var text: String
    }

    @Published private(set) var shown: Shown? {
        didSet {
        }
    }

    func enter(_ id: String, text: String) {
        let new = Shown(id: id, text: text)
        if shown != new { shown = new }
    }

    /// Only for the block shown: the next one may have taken over already
    func leave(_ id: String) {
        if shown?.id == id { shown = nil }
    }

    func clear() {
        if shown != nil { shown = nil }
    }
}

/// Which block shows its hover text as if the mouse were on it: the first or the last of the first row of the first station
/// with times
enum PlannerTipSample {
    case first, last
}

/// Where the hover text goes: the bounds of the block the mouse is on (PlannerTipSource, PlannerTipLayer)
struct PlannerTipAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Makes a block show its hover text at once (PlannerHover): while the mouse is on it, its edge is darker and a little thicker and the
/// text hangs below it (PlannerTipLayer)
struct PlannerTipSource: ViewModifier {
    @ObservedObject var hover: PlannerHover
    var id: String
    var text: String
    /// Shown as if the mouse were on it (PlannerTipSample)
    var sample: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let on = hover.shown?.id == id
        content
            .overlay {
                if on {
                    RoundedRectangle(cornerRadius: PlannerChip.cornerRadius)
                        .strokeBorder(contrast == .increased ? Color.primary : Color.primary.opacity(0.4), lineWidth: 1.5)
                }
            }
            .anchorPreference(key: PlannerTipAnchor.self, value: .bounds) { on ? $0 : nil }
            .onHover { inside in
                if inside { hover.enter(id, text: text) } else { hover.leave(id) }
            }
            // New times while the mouse stays on it
            .onChange(of: text) { _, new in
                if hover.shown?.id == id { hover.enter(id, text: new) }
            }
            // Gone (scrolled away, or new results) while the mouse was on it
            .onDisappear { hover.leave(id) }
            .onChange(of: sample, initial: true) { _, isSample in
                if isSample { hover.enter(id, text: text) }
            }
    }
}

/// The text of the block the mouse is on, like a tooltip (PlannerTipBubble): 4 points below the block, lined up with its leading side,
/// or with the other when it would go past the window; above the block when there's no room below. The block's bounds come counted
/// from the left even from right to left, while `position` counts from the leading side: so from right to left they're turned
/// around first (fromLeading), or the text would land on the other side of the window. Shown once its size is known, so it doesn't
/// jump. Takes no clicks; screen readers get the text from the block itself
struct PlannerTipLayer: View {
    @ObservedObject var hover: PlannerHover
    var anchor: Anchor<CGRect>?
    @Environment(\.layoutDirection) private var direction
    @State private var measured: Measured?

    private struct Measured: Equatable {
        var text: String
        var size: CGSize
    }

    var body: some View {
        GeometryReader { proxy in
            if let shown = hover.shown, let anchor {
                let size = measured?.text == shown.text ? measured?.size : nil
                PlannerTipBubble(text: shown.text)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                        measured = Measured(text: shown.text, size: newSize)
                    }
                    // Another text: measured anew
                    .id(shown.text)
                    .opacity(size == nil ? 0 : 1)
                    .position(Self.center(size ?? .zero,
                                          block: Self.fromLeading(proxy[anchor], width: proxy.size.width, direction: direction),
                                          room: proxy.size))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The block's bounds counted from the leading side, the way `position` counts: from right to left, from the window's right edge
    static func fromLeading(_ block: CGRect, width: CGFloat, direction: LayoutDirection) -> CGRect {
        guard direction == .rightToLeft else { return block }
        return CGRect(x: width - block.maxX, y: block.minY, width: block.width, height: block.height)
    }

    /// Where the text's middle goes, counted from the leading side (`block` too). 8 points are kept clear at the window's edges: lined
    /// up with the block's leading side, or with its other side when the text would go past the edge that way (pushed in if it still
    /// would); above the block when it would go past the bottom and there's room above
    static func center(_ size: CGSize, block: CGRect, room: CGSize) -> CGPoint {
        let margin: CGFloat = 8
        let gap: CGFloat = 4
        var x = block.minX
        if x + size.width > room.width - margin { x = block.maxX - size.width }
        x = max(margin, min(x, room.width - margin - size.width))
        var y = block.maxY + gap
        if y + size.height > room.height - margin, block.minY - gap - size.height >= margin {
            y = block.minY - gap - size.height
        }
        return CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }
}

/// A block's hover text in a small box like the system's tooltip (window background, thin edge, soft shadow), as wide as its lines up
/// to 320 points (more with larger text), wrapped beyond
private struct PlannerTipBubble: View {
    var text: String

    var body: some View {
        UpToWidth(maxWidth: 320 * TextScale.factor) {
            Text(text)
                .font(.scaled(.subheadline))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .contrastBorder(cornerRadius: 5)
        .shadow(color: .black.opacity(0.18), radius: 5, y: 3)
    }
}

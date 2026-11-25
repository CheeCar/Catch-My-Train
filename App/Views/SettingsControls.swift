import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// Fitting a number typed into a Settings field to the field: the value kept (rounded to the step, within the range), and whether
/// that changed what was typed, which the row then says
enum NumberFit {
    static func kept(_ typed: Double, range: ClosedRange<Double>, step: Double) -> Double {
        let stepped = (typed / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// More than a rounding error apart: 4.5 + 0.1 from the +/- buttons is 4.6000000000000005, which isn't a change
    static func changed(_ typed: Double, to kept: Double, step: Double) -> Bool {
        !(abs(typed - kept) <= step / 1000)
    }
}

/// One choice in a SettingSegments switch: its value, its name, and an optional symbol before the name
struct SettingChoice<Value: Hashable> {
    let value: Value
    let name: String
    var symbol: String?

    init(_ value: Value, _ name: String, symbol: String? = nil) {
        self.value = value
        self.name = name
        self.symbol = symbol
    }

    var text: SegmentText { SegmentText(name: name, symbol: symbol) }
}

/// What a segment shows, whatever its value: used to measure the switches of a group
struct SegmentText {
    let name: String
    let symbol: String?
}

/// Switches that are all as wide as the widest of them: their titles and what their segments show (SettingSegments.group)
struct SegmentGroup {
    let titles: [String]
    let choices: [[SegmentText]]
}

/// A Settings row of four views: the title, two hidden views that are only measured (the widest title and the widest switch of the row's group),
/// and the switch. All switches of a group get the same width and height: the widest one's width and the tallest one's height.
/// When the widest switch fits beside the widest title at full size, the title is on the leading side and the switch on the trailing side,
/// both centered vertically. Otherwise the title is on a line of its own, and the switch below it takes the whole width.
/// Every row of a group measures the same views, so they all choose the same way. It places the views itself, from the right in right-to-left languages,
/// so it is used in a left-to-right environment (see SettingSegments).
private struct SettingRowLayout: Layout {
    var rightToLeft = false
    var spacing: CGFloat = 12
    /// Space between the title and the switch below it
    var lineSpacing: CGFloat = 6

    private struct Plan {
        var stacked: Bool
        var title: CGFloat
        var control: CGFloat
    }

    /// Side by side or stacked, and the widths of the title and the switch within `width`
    private func plan(_ subviews: Subviews, in width: CGFloat?) -> Plan {
        let title = subviews[1].sizeThatFits(.unspecified).width
        let control = subviews[2].sizeThatFits(.unspecified).width
        guard let width else { return Plan(stacked: false, title: title, control: control) }
        if control <= width - spacing - title {
            return Plan(stacked: false, title: width - spacing - control, control: control)
        }
        return Plan(stacked: true, title: width, control: width)
    }

    /// The group's tallest switch, or this one when its text has to wrap
    private func controlHeight(_ subviews: Subviews, width: CGFloat) -> CGFloat {
        max(subviews[2].sizeThatFits(.unspecified).height, subviews[3].sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 4 else { return .zero }
        let row = plan(subviews, in: proposal.width)
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: row.title, height: nil)).height
        let control = controlHeight(subviews, width: row.control)
        return CGSize(width: proposal.width ?? row.title + spacing + row.control,
                      height: row.stacked ? title + lineSpacing + control : max(title, control))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let row = plan(subviews, in: bounds.width)
        let titleProposal = ProposedViewSize(width: row.title, height: nil)
        let controlProposal = ProposedViewSize(width: row.control, height: controlHeight(subviews, width: row.control))
        let titleX = rightToLeft ? bounds.maxX - row.title : bounds.minX
        let controlX = rightToLeft ? bounds.minX : bounds.maxX - row.control
        subviews[1].place(at: bounds.origin, proposal: .unspecified)
        subviews[2].place(at: bounds.origin, proposal: .unspecified)
        if row.stacked {
            let titleHeight = subviews[0].sizeThatFits(titleProposal).height
            subviews[0].place(at: CGPoint(x: titleX, y: bounds.minY), anchor: .topLeading, proposal: titleProposal)
            subviews[3].place(at: CGPoint(x: controlX, y: bounds.minY + titleHeight + lineSpacing), anchor: .topLeading, proposal: controlProposal)
        } else {
            subviews[0].place(at: CGPoint(x: titleX, y: bounds.midY), anchor: .leading, proposal: titleProposal)
            subviews[3].place(at: CGPoint(x: controlX, y: bounds.midY), anchor: .leading, proposal: controlProposal)
        }
    }
}

/// A segmented setting drawn by the app instead of the system control, so it looks and moves like the switches in the main window:
/// the selected segment is white on blue, and the blue slides over to a new choice (instantly with "Reduce motion").
/// The segments share the width equally. The switch is as wide as the widest switch of its group (each measured with its segments
/// as wide as its widest), so the group lines up on both sides; when that doesn't fit beside the titles, the titles go above (SettingRowLayout).
/// Only when even the whole row is too narrow does a segment's text go onto two lines (then shrink a little, then truncate; hovering shows it all).
struct SettingSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [SettingChoice<Value>]
    /// The switches that should be as wide as this one, this one included (nil: only this one)
    var group: SegmentGroup?
    /// The whole row, without the title beside it (the section header already says what it's for)
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var direction
    @Namespace private var space

    var body: some View {
        if fullWidth {
            // Segments as tall as the tallest (each fills the height, which comes from the tallest)
            segments
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        } else {
            // A layout of its own instead of LabeledContent: the title is centered on the switch, and the switch can be as wide as its group
            SettingRowLayout(rightToLeft: direction == .rightToLeft) {
                // Grayed out with the segments, like the label of a system control
                Text(title)
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                    .environment(\.layoutDirection, direction)
                widestTitle
                widestSwitch
                segments
                    .environment(\.layoutDirection, direction)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    /// Hidden: as wide as the widest title of the group
    private var widestTitle: some View {
        ZStack {
            ForEach(Array((group?.titles ?? [title]).enumerated()), id: \.offset) { _, text in
                Text(text)
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// Hidden: as wide as the widest switch of the group, each with its segments as wide as its widest one (in the selected weight)
    private var widestSwitch: some View {
        ZStack {
            ForEach(Array((group?.choices ?? [choices.map(\.text)]).enumerated()), id: \.offset) { _, texts in
                EqualWidthStack(spacing: 2) {
                    ForEach(texts.indices, id: \.self) { i in
                        segmentText(texts[i], on: true, lines: 1)
                    }
                }
                .padding(2)
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(choices.indices, id: \.self) { i in
                segment(choices[i])
            }
        }
        .segmentThumb(selection, in: space, cornerRadius: 5)
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
        // Grayed out like the system control when it can't be used
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// A segment's name (and symbol), with the padding inside its blue; on at most `lines` lines
    private func segmentText(_ text: SegmentText, on: Bool, lines: Int) -> some View {
        Group {
            if let symbol = text.symbol {
                Label(text.name, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
            } else {
                Text(text.name)
            }
        }
        .fontWeight(on ? .semibold : .regular)
        .lineLimit(lines)
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.85)
        .truncationMode(.tail)
        .frame(minHeight: 20)
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
    }

    private func segment(_ choice: SettingChoice<Value>) -> some View {
        let on = choice.value == selection
        return Button {
            if !on { selection = choice.value }
        } label: {
            segmentText(choice.text, on: on, lines: 2)
                .foregroundStyle(on ? Color.white : Color.primary)
                // Fills the switch's height, so all segments (and the blue) are as tall as the tallest
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .segmentSlot(choice.value, in: space)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.name)
        // Screen readers: say which one is selected (on screen only color shows it)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A numeric setting row: the allowed range under the name (e.g. "3 to 30"), a text field and +/- buttons.
/// Typed numbers outside the range snap to the nearest bound and are rounded to the step; when that changes what was typed,
/// a line under the name says so ("Changed to 30 min, the nearest allowed value."), and screen readers hear it.
/// `unit`: the value as screen readers say it after the name, from the number as the field shows it ("15 min")
struct SettingNumberRow: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let l: UIText
    let note: String?
    /// The field of this page whose typed number was changed to fit (outside the range, or between two steps): its title and
    /// the value kept, said under that field until the next change
    @Binding var adjusted: (title: String, value: Double)?
    /// How many times each field's typed number was changed to fit: the field is made again then, so it shows the value kept
    /// even when that's the value it had before
    @Binding var fitCounts: [String: Int]
    let unit: (String) -> String

    var body: some View {
        let digits = step < 1 ? 1 : 0
        func spoken(_ v: Double) -> String { unit(l.number(v, fractionDigits: v == v.rounded() ? 0 : digits)) }
        let clamped = Binding<Double>(
            get: { value.wrappedValue },
            set: { new in
                let kept = NumberFit.kept(new, range: range, step: step)
                value.wrappedValue = kept
                if NumberFit.changed(new, to: kept, step: step) {
                    adjusted = (title, kept)
                    fitCounts[title, default: 0] &+= 1
                    // Screen readers hear it too
                    announceToScreenReaders(l.f("Changed to %@, the nearest allowed value.", spoken(kept)))
                } else if adjusted != nil {
                    adjusted = nil
                }
            })
        let rangeText = l.f("%@ to %@", l.number(range.lowerBound, fractionDigits: digits),
                            l.number(range.upperBound, fractionDigits: digits))
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                // Screen readers get the name from the field and the +/- buttons beside it; as a text of its own too, they said it three times
                Text(title)
                    .accessibilityHidden(true)
                Text(note.map { rangeText + " · " + $0 } ?? rangeText)
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                if let adjusted, adjusted.title == title {
                    Text(l.f("Changed to %@, the nearest allowed value.", spoken(adjusted.value)))
                        .font(.scaled(.caption))
                        .foregroundStyle(Color.noticeOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            TextField("", value: clamped, format: .number.precision(.fractionLength(0...1)))
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text(title))
                // Made again after a change to fit, so it shows the value kept, not what was typed
                .id(fitCounts[title] ?? 0)
            // Named once (with a title of its own as well, screen readers said the name twice), then the value with its unit
            Stepper(value: clamped, in: range, step: step) { EmptyView() }
                .labelsHidden()
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(spoken(clamped.wrappedValue)))
        }
    }
}

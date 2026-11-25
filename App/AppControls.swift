import AppKit
import CatchText
import SwiftUI
import TransitCore
import WidgetKit

/// Icon and title with the icon in a column of fixed width, so the titles of labels stacked one above the other start at the same place:
/// SF Symbols differ in width ("scope" is wider than "clock"). The column is as wide as `widest` drawn in the same font,
/// so it grows with the text size; use the widest symbol of the list.
struct IconColumnLabelStyle: LabelStyle {
    var widest = "dot.radiowaves.left.and.right"

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ZStack {
                Image(systemName: widest).hidden()
                configuration.icon
            }
            configuration.title
        }
    }
}

/// The look of the small buttons in the sidebar (Choose a New Place, Change, Extend Range for Now) and the place picker's Undo: flat,
/// in the light gray of the sidebar's location switch (LocationModeSwitch), with no edge or shadow, so they belong to the sidebar instead
/// of standing out from it; a little darker on hover and while pressed, and a clear edge when Increase Contrast is on. Drawn here
/// instead of using the system's small buttons, whose text doesn't follow the app's Text size. System colors only. Buttons get it from
/// SmallBezelButtonStyle; a menu draws it on its own label (TempRangeMenu).
struct SmallBezel: ViewModifier {
    var hovering = false
    var pressed = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(shape.fill(Color.secondary.opacity(pressed ? 0.3 : hovering ? 0.2 : 0.12)))
            .contrastBorder(cornerRadius: 5)
            .contentShape(shape)
    }
}

/// A button with the small bezel (SmallBezel): text and icon in the primary color, gray when it can't be used.
struct SmallBezelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SmallBezelButton(configuration: configuration)
    }

    private struct SmallBezelButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .modifier(SmallBezel(hovering: hovering && isEnabled, pressed: configuration.isPressed))
                .onHover { hovering = $0 }
        }
    }
}

/// How a button looked before it followed the app's Text size (appButtonStyle): the system's style it keeps at Standard
enum AppButtonKind {
    /// No style of its own: the system's push button
    case automatic
    /// The system's bordered button
    case bordered
    /// The system's blue button
    case prominent
    /// The window's default button (Return), which the system draws blue: no style of its own at Standard, blue when the app draws it
    case defaultAction
}

extension View {
    /// Buttons whose text follows the app's Text size. The system's buttons keep macOS's own text size, so at Large and Larger the app
    /// draws them itself in the same look (AppButtonStyle); at Standard they stay the system's, unchanged. A window is made anew when the
    /// text size changes (the .id(transit.textSize) on each), so reading TextScale.factor here is enough
    @ViewBuilder
    func appButtonStyle(_ kind: AppButtonKind = .automatic) -> some View {
        if TextScale.factor == 1 {
            switch kind {
            case .automatic, .defaultAction:
                self
            case .bordered:
                buttonStyle(.bordered)
            case .prominent:
                buttonStyle(.borderedProminent)
            }
        } else {
            buttonStyle(AppButtonStyle(prominent: kind == .prominent || kind == .defaultAction))
        }
    }
}

/// The look of the app's own buttons and pop-up menus at Large and Larger (appButtonStyle, AppMenuPicker), drawn like the system's
/// push buttons at Standard: white with a thin edge and a faint shadow (gray in dark mode), or the accent color with white text for a
/// window's main button; size, corners and text times the text size, by the control size (small, regular, large). A little darker while
/// pressed, gray text when it can't be used, a clear edge when Increase Contrast is on. System colors only
struct AppBezel: ViewModifier {
    var prominent = false
    var pressed = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let f = TextScale.factor
        let small = controlSize == .small || controlSize == .mini
        let large = controlSize == .large || controlSize == .extraLarge
        let radius = (small ? 5 : 6) * f
        let shape = RoundedRectangle(cornerRadius: radius)
        // The accent color only while it can be used and its window is in front, as the system's
        let accent = prominent && isEnabled && activeState != .inactive
        content
            .font(.scaled(small ? .subheadline : .body))
            .foregroundStyle(accent ? Color.white : isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, (small ? 8 : large ? 14 : 10) * f)
            .padding(.vertical, (small ? 1 : large ? 5 : 2) * f)
            .frame(minHeight: (small ? 19 : large ? 28 : 22) * f)
            .background {
                shape
                    .fill(accent ? Color.accentColor : Color(nsColor: .controlColor))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.18), radius: 0.5, y: 0.5)
            }
            .overlay {
                if !accent {
                    shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                }
            }
            .overlay(shape.fill(Color.black.opacity(pressed ? 0.12 : 0)))
            .contrastBorder(cornerRadius: radius)
            .contentShape(shape)
    }
}

/// A button drawn by the app (AppBezel), for appButtonStyle at Large and Larger
struct AppButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(AppBezel(prominent: prominent, pressed: configuration.isPressed))
    }
}

/// A pop-up menu whose button follows the app's Text size: at Standard the system's own (a Picker in the menu style), unchanged; at
/// Large and Larger a menu with the same choices inside, the chosen one checked as before, and its button drawn by the app in the
/// system's look (AppMenuLabel). The list that opens is the system's menu, in macOS's own text size. The title is the row's label,
/// hidden by .labelsHidden() as before
struct AppMenuPicker<Value: Hashable, Choices: View>: View {
    let title: String
    @Binding var selection: Value
    /// The chosen value's words, on the button
    let valueText: String
    /// In a Settings form: only the words and the small arrows, as the system's pop-ups there; elsewhere a bordered button
    let plain: Bool
    let choices: Choices

    init(_ title: String, selection: Binding<Value>, valueText: String, plain: Bool = false, @ViewBuilder choices: () -> Choices) {
        self.title = title
        _selection = selection
        self.valueText = valueText
        self.plain = plain
        self.choices = choices()
    }

    var body: some View {
        if TextScale.factor == 1 {
            Picker(title, selection: $selection) {
                choices
            }
            .pickerStyle(.menu)
        } else {
            LabeledContent(title) {
                Menu {
                    Picker(title, selection: $selection) {
                        choices
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    AppMenuLabel(text: valueText, plain: plain)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
            }
        }
    }
}

/// The button of an AppMenuPicker at Large and Larger, and of Settings' Language row (LanguageSetting), which opens a list: the
/// chosen value and the small up and down arrows, plain (in a Settings form) or bordered with the arrows in a small accent-colored
/// box at its end
struct AppMenuLabel: View {
    let text: String
    let plain: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let f = TextScale.factor
        if plain {
            HStack(spacing: 5 * f) {
                Text(text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9 * f, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.scaled(.body))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .lineLimit(1)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 6 * f) {
                Text(text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8 * f, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16 * f, height: 16 * f)
                    .background(RoundedRectangle(cornerRadius: 4 * f).fill(isEnabled ? Color.accentColor : Color.secondary))
            }
            .lineLimit(1)
            // The box sits close to the button's end, as in the system's pop-ups
            .padding(.trailing, -6 * f)
            .modifier(AppBezel())
        }
    }
}

/// Buttons that sit side by side as equals: the same width (as wide as the widest) and height, stacked when the space is too narrow,
/// in the language's direction. Each button's label needs .frame(maxWidth: .infinity) so its bezel fills the width it gets.
struct EqualWidthButtons<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        EqualWidthStack(rightToLeft: direction == .rightToLeft, spacing: spacing) {
            content.environment(\.layoutDirection, direction)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Buttons side by side with the same width: as wide as the widest, or a little narrower to fit, with their text shrinking slightly
/// (a pair doesn't look one big, one small). Stacked when they would have to shrink more than that.
/// It places them itself, from the right in right-to-left languages, so it is used in a left-to-right environment (EqualWidthButtons does that).
struct EqualWidthStack: Layout {
    var rightToLeft = false
    var spacing: CGFloat = 10

    /// The widest button's width and the tallest one's height
    private func cell(_ subviews: Subviews) -> CGSize {
        subviews.reduce(CGSize.zero) { size, view in
            let fit = view.sizeThatFits(.unspecified)
            return CGSize(width: max(size.width, fit.width), height: max(size.height, fit.height))
        }
    }

    /// Width of each button side by side within `width`, or nil when they would have to shrink by more than a little
    private func sideBySideWidth(_ cell: CGSize, count: Int, in width: CGFloat?) -> CGFloat? {
        guard let width else { return cell.width }
        let gaps = spacing * CGFloat(max(count - 1, 0))
        let each = min(cell.width, (width - gaps) / CGFloat(max(count, 1)))
        return each >= cell.width * 0.95 ? each : nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let c = cell(subviews)
        let n = CGFloat(subviews.count)
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        if let each = sideBySideWidth(c, count: subviews.count, in: proposal.width) {
            return CGSize(width: each * n + gaps, height: c.height)
        }
        return CGSize(width: min(c.width, proposal.width ?? c.width), height: c.height * n + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let c = cell(subviews)
        if let each = sideBySideWidth(c, count: subviews.count, in: proposal.width) {
            for (i, view) in subviews.enumerated() {
                let slot = CGFloat(rightToLeft ? subviews.count - 1 - i : i)
                view.place(at: CGPoint(x: bounds.minX + slot * (each + spacing), y: bounds.minY),
                           proposal: ProposedViewSize(width: each, height: c.height))
            }
        } else {
            let width = min(c.width, bounds.width)
            for (i, view) in subviews.enumerated() {
                view.place(at: CGPoint(x: bounds.minX, y: bounds.minY + CGFloat(i) * (c.height + spacing)),
                           proposal: ProposedViewSize(width: width, height: c.height))
            }
        }
    }
}

/// Its one view as wide as it wants to be, up to `maxWidth` (wrapped beyond), however much or little room it's offered, and as tall
/// as it is at that width. A frame with only a largest width doesn't do it where nothing proposes a size, as in a popover or an
/// image drawn of a view: there a long sentence is measured on one line, then drawn wrapped, and cut off at the top and the bottom.
/// Used by Plan a Trip's hover text and a train's details
struct UpToWidth: Layout {
    var maxWidth: CGFloat

    private func childProposal(_ subviews: Subviews) -> ProposedViewSize {
        let ideal = subviews.first?.sizeThatFits(.unspecified).width ?? 0
        return ProposedViewSize(width: min(ideal, maxWidth), height: nil)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(childProposal(subviews)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: childProposal(subviews))
    }
}

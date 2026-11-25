import CatchText
import SwiftUI
import TransitCore

/// The commute presets as small buttons, under the starting place in the main window's sidebar and under the mode line in the
/// menu bar's panel: as many side by side as fit, the rest on the next lines (PresetButtonsLayout). A click walks from the
/// preset's place and shows its mode (TransitModel.usePreset); the one in use now is blue; one that can't be used now is gray, its
/// hover text saying why. Nothing at all while there are no presets. Presets are made in Settings, General.
/// It watches the presets, not the main model, which doesn't publish their changes.
struct PresetButtons: View {
    @EnvironmentObject var transit: TransitModel
    @ObservedObject var presets: CommutePresetCenter

    /// What the buttons show that decides how many lines they take: each one's name and mode. The sidebar makes its row new when
    /// this changes (see PresetSidebarRow); nothing while there are no presets
    static func lines(_ presets: [CommutePreset]) -> [String] {
        let shown = CommutePresets.shown(presets)
        // A name is on one line with single spaces (CommutePresets.cleanName): tabs and line breaks can't be in it
        return shown.isEmpty ? [] : [shown.map { $0.name + "\t" + $0.system }.joined(separator: "\n")]
    }

    var body: some View {
        let shown = CommutePresets.shown(presets.presets)
        if !shown.isEmpty {
            let active = transit.activePreset?.id
            PresetButtonsLayout(spacing: 6) {
                ForEach(shown) { preset in
                    PresetButton(name: preset.name, symbol: preset.mode?.symbol ?? "questionmark.circle", on: preset.id == active,
                                 usable: transit.presetState(preset) == .ready, note: transit.presetNote(preset),
                                 comma: transit.l10n.comma) {
                        transit.usePreset(preset)
                    }
                }
            }
            // One group for screen readers, named, with the buttons inside it
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(transit.l10n.t("Commute presets")))
        }
    }
}

/// The presets in the sidebar's list: one row, only while there are presets, made new whenever what decides its height changes
/// (their names and modes): a list row's height doesn't follow its content. Its width is the sidebar's, which the list measures
struct PresetSidebarRow: View {
    @ObservedObject var presets: CommutePresetCenter

    var body: some View {
        ForEach(PresetButtons.lines(presets.presets), id: \.self) { _ in
            PresetButtons(presets: presets)
                .padding(.vertical, 2)
                .selectionDisabled()
        }
    }
}

/// One preset's button: the mode's symbol and the name, on one line (cut short with "…" when even a line of its own is too
/// narrow; the hover text has no name, the button is named for screen readers). Blue with white text while it's the one in use;
/// light gray otherwise, a little darker under the pointer; gray text when it can't be used. A clear edge with Increase Contrast
private struct PresetButton: View {
    let name: String
    let symbol: String
    let on: Bool
    let usable: Bool
    /// Where it walks from and its mode, or why it can't be used: the hover text, and what screen readers say after the name
    let note: String
    /// Between the name and the note for screen readers (UIText.comma)
    let comma: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.scaled(.callout))
            .foregroundStyle(on ? Color.white : usable ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(shape.fill(on ? Color.accentColor : Color.secondary.opacity(hovering && usable ? 0.2 : 0.12)))
            .contrastBorder(cornerRadius: 6)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .onHover { hovering = $0 }
        .help(note)
        // All in the name, the name first: macOS reads a value before the name
        .accessibilityLabel(Text(name + comma + note))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Views side by side in lines as wide as the space: each as wide as it wants, up to the whole line (narrower then, so a long
/// name is cut short), as many on a line as fit, the rest on the next lines; centered in the line's height. From the leading
/// side: the system mirrors this in right-to-left languages
struct PresetButtonsLayout: Layout {
    var spacing: CGFloat

    private struct Item {
        var index: Int
        var size: CGSize
    }

    /// The lines within `width` (one line when nothing limits it)
    private func lines(_ subviews: Subviews, width: CGFloat?) -> [[Item]] {
        let limit = width.flatMap { $0.isFinite ? max($0, 1) : nil }
        var lines: [[Item]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            if let limit, size.width > limit {
                size = view.sizeThatFits(ProposedViewSize(width: limit, height: nil))
                size.width = min(size.width, limit)
            }
            if let limit, let last = lines.last, !last.isEmpty, x + spacing + size.width > limit {
                lines.append([])
                x = 0
            }
            x += (lines[lines.count - 1].isEmpty ? 0 : spacing) + size.width
            lines[lines.count - 1].append(Item(index: i, size: size))
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (n, line) in lines(subviews, width: proposal.width).enumerated() {
            width = max(width, line.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(line.count - 1, 0)))
            height += (line.map(\.size.height).max() ?? 0) + (n > 0 ? spacing : 0)
        }
        if let w = proposal.width, w.isFinite { width = w }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            let height = line.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in line {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2),
                                           proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }
}

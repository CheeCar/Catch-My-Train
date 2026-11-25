import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// The Settings window: a column of pages at the leading edge, and the page chosen there beside it.
struct SettingsView: View {
    @EnvironmentObject var transit: TransitModel
    /// The page shown, kept so the window opens on it again
    @AppStorage(SettingsPage.storageKey) private var page: SettingsPage = .general

    var body: some View {
        let l = transit.l10n
        HStack(spacing: 0) {
            SettingsSidebar(page: page, l: l) { page = $0 }
            Divider()
            Group {
                switch page {
                case .general: GeneralSettingsPage()
                case .running: RunningSettingsPage()
                case .privacy: PrivacySettingsPage()
                case .searchRange: RangeSettingsPage()
                case .dataSource: SourceSettingsPage()
                case .reminders: RemindersSettingsPage()
                case .about: AboutSettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The window title is the page's name, set here so it follows a language change
        .navigationTitle(page.name(l))
        // A place asked for on another page (SettingsJump): that page is shown, and it scrolls there itself once it is there
        .onAppear { showJumpPage() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsJump.requested)) { _ in showJumpPage() }
    }

    private func showJumpPage() {
        guard let target = SettingsJump.pending, target.page != page else { return }
        page = target.page
    }
}

/// The pages of the Settings window, in the order of the column
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case running
    case privacy
    case searchRange = "search-range"
    case dataSource = "data-source"
    case reminders
    case about

    /// Where the page shown is kept
    static let storageKey = "settingsPage"

    var id: String { rawValue }

    /// The page's name, in the column and as the window title
    func name(_ l: UIText) -> String {
        switch self {
        case .general: return l.t("General")
        case .running: return l.t("Running")
        case .privacy: return l.t("Privacy")
        case .searchRange: return l.t("Search range")
        case .dataSource: return l.t("Data source")
        case .reminders: return l.t("Reminders")
        case .about: return l.t("About")
        }
    }

    /// The page's icon in the column
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .running: return "play.circle"
        case .privacy: return "lock"
        case .searchRange: return "target"
        case .dataSource: return "tray.and.arrow.down"
        case .reminders: return "bell"
        case .about: return "info.circle"
        }
    }

}

/// Sizes of the column of pages. Its width is worked out from the names, so the window's smallest width can follow it
enum SettingsColumn {
    /// From the column's edge to a row's background
    static let inset: CGFloat = 10
    /// From a row's background to its icon and name
    static let rowInset: CGFloat = 8
    /// The room an icon has at the standard text size
    static let iconWidth: CGFloat = 20
    static let iconGap: CGFloat = 6
    /// The column is never narrower than this at the standard text size
    static let minWidth: CGFloat = 150
    /// The narrowest a page beside the column gets
    static let pageMinWidth: CGFloat = 480
    /// The window as it first opens
    static let defaultSize = CGSize(width: 720, height: 660)
    static let windowMinHeight: CGFloat = 400

    /// The width at which the longest page name is whole on one line, in the app's language and at its text size now
    static func width(_ l: UIText) -> CGFloat {
        let scale = TextScale.factor
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize * scale)
        let longest = SettingsPage.allCases
            .map { ($0.name(l) as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let needed = 2 * (inset + rowInset) + iconWidth * scale + iconGap + longest.rounded(.up) + 6
        return max(minWidth * scale, needed)
    }

    /// The window's smallest width: the column, the line beside it and the narrowest page
    static func windowMinWidth(_ l: UIText) -> CGFloat { width(l) + 1 + pageMinWidth }
}

/// The column of pages: one row each, the page shown filled with the accent color. It follows the app's text size and is as
/// wide as its longest name needs (SettingsColumn.width), so no name is cut short in any language
struct SettingsSidebar: View {
    let page: SettingsPage
    let l: UIText
    let choose: (SettingsPage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { item in
                SettingsSidebarRow(symbol: item.symbol, name: item.name(l), chosen: item == page) { choose(item) }
            }
        }
        .padding(.horizontal, SettingsColumn.inset)
        .padding(.vertical, 10)
        .frame(width: SettingsColumn.width(l))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.04))
    }
}

/// One page in the column: its icon and name, to click. Lightly shaded under the mouse
private struct SettingsSidebarRow: View {
    let symbol: String
    let name: String
    let chosen: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: SettingsColumn.iconGap) {
                Image(systemName: symbol)
                    .foregroundStyle(chosen ? Color.white : Color.accentColor)
                    .frame(width: SettingsColumn.iconWidth * TextScale.factor)
                    .accessibilityHidden(true)
                Text(name)
                    .lineLimit(1)
                    .foregroundStyle(chosen ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsColumn.rowInset)
            .padding(.vertical, 5 * TextScale.factor)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(chosen ? Color.accentColor : hovering ? Color.primary.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(name)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// One page of Settings: its sections in a grouped form that scrolls, and the jump to a place on it (SettingsJump)
struct SettingsPageForm<Content: View>: View {
    let page: SettingsPage
    /// Called with the place asked for on this page, before the page scrolls there
    let onJump: (SettingsJump.Target) -> Void
    let content: () -> Content

    init(_ page: SettingsPage, onJump: @escaping (SettingsJump.Target) -> Void = { _ in },
         @ViewBuilder content: @escaping () -> Content) {
        self.page = page
        self.onJump = onJump
        self.content = content
    }

    var body: some View {
        ScrollViewReader { scroller in
            Form(content: content)
                .formStyle(.grouped)
                .padding()
                // Asked for while the window was closed or showed another page: once this page is there, a moment later so
                // it is laid out. Asked for while this page is shown: at once
                .onAppear { show(scroller, after: 0.4) }
                .onReceive(NotificationCenter.default.publisher(for: SettingsJump.requested)) { _ in show(scroller, after: 0) }
        }
    }

    /// Brings the page to the place that was asked for, when that place is on this page
    private func show(_ scroller: ScrollViewProxy, after delay: Double) {
        guard let target = SettingsJump.pending, target.page == page else { return }
        SettingsJump.pending = nil
        onJump(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(Motion.ease(0.2)) { scroller.scrollTo(target.id, anchor: .top) }
        }
    }
}

/// A request to bring the Settings window to one of its places (the "Data Source…" button in the sidebar header's popover, for
/// one). The request waits here until the place's page is there to scroll, as the window may only just be opening or may be
/// showing another page
enum SettingsJump {
    /// The places a button elsewhere can open Settings at: next to a sentence that says what to change there
    enum Target: String, CaseIterable {
        /// Data source, showing the main window's transit mode and the start place's metro area
        case dataSource = "data-source"
        /// Keys and accounts, at the top of Data source (the start place's metro area)
        case keys
        case privacy
        /// Downloaded data, under Data source
        case downloadedData = "downloaded-data"
        /// Downloaded data's last row, "All downloaded data" with Delete Downloaded Data…
        case downloadedTotal = "downloaded-total"
        case searchRange = "search-range"
        case demo
        /// Updates, where "Check for Updates…" shows its result
        case updates

        /// The view id it scrolls to
        var id: String { "settings-" + rawValue }

        /// The page the place is on
        var page: SettingsPage {
            switch self {
            case .dataSource, .keys, .downloadedData, .downloadedTotal, .demo: return .dataSource
            case .privacy: return .privacy
            case .searchRange: return .searchRange
            case .updates: return .about
            }
        }
    }

    /// The data source section's header on its page
    static var dataSourceID: String { Target.dataSource.id }
    static let requested = Notification.Name("CatchMyTrainSettingsJump")
    /// Asked for, and its page hasn't gone there yet
    static var pending: Target?

    static func to(_ target: Target) {
        pending = target
        NotificationCenter.default.post(name: requested, object: nil)
    }

    static func toDataSource() { to(.dataSource) }
}

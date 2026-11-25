import SwiftUI

/// The look of a section's title on a Settings page: heavier and one size larger than the rows under it, with a little more room
/// above it, so the sections are easy to tell apart. It follows the app's text size
private struct SettingsSectionTitleStyle: ViewModifier {
    let spaceAbove: Bool

    /// The extra room above a title
    static var space: CGFloat { 6 * TextScale.factor }

    func body(content: Content) -> some View {
        content
            .font(.scaled(.title3).weight(.semibold))
            .foregroundStyle(Color.primary)
            .padding(.top, spaceAbove ? Self.space : 0)
    }
}

extension View {
    /// A Settings section's title (SettingsSectionTitleStyle), for a header written out because it has an id to scroll to or holds
    /// more than its name. spaceAbove false: the header gives itself the room above (settingsSectionSpaceAbove)
    func settingsSectionTitle(spaceAbove: Bool = true) -> some View {
        modifier(SettingsSectionTitleStyle(spaceAbove: spaceAbove))
    }

    /// The room above a section's title, for a header with something beside the title: the whole header gets it, so the two stay in line
    func settingsSectionSpaceAbove() -> some View { padding(.top, SettingsSectionTitleStyle.space) }
}

/// A section of a Settings page whose header is only its name, in the pages' title style
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(title).settingsSectionTitle()
        }
    }
}

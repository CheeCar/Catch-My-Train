import CatchText
import SwiftUI
import TransitCore

private struct DirectionsActionKey: EnvironmentKey {
    static let defaultValue: DirectionsAction? = nil
}

extension EnvironmentValues {
    /// "Directions" for the station page (TransitModel.directionsAction): set by the main window, nil anywhere else
    var directions: DirectionsAction? {
        get { self[DirectionsActionKey.self] }
        set { self[DirectionsActionKey.self] = newValue }
    }
}

/// The "Directions" button, never blue (blue is for the reminder's button): at the top of the station page a small one with a
/// light gray background like the sidebar's (`small`), in a train's details a bordered one like "Cancel Reminder".
/// Its hover text, which screen readers say too, tells what it opens and in which map
struct DirectionsButton: View {
    var l: UIText
    var mapName: String
    var small = false
    var action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Label(l.t("Directions"), systemImage: "arrow.up.forward.square")
        }
        .help(l.f("Opens the walking route to this station in %@.", mapName))
        .lineLimit(1)
        .fixedSize()
        if small {
            button.buttonStyle(SmallBezelButtonStyle())
        } else {
            button.appButtonStyle(.bordered)
        }
    }
}

import XCTest
@testable import CatchText
import TransitCore

/// The words of "Directions": the two maps it can open, and the sentences that point at the button.
final class DirectionsTextTests: XCTestCase {
    func testMapNames() {
        let english = AppText()
        XCTAssertEqual(english.mapName(.appleMaps), "Apple Maps")
        XCTAssertEqual(english.mapName(.googleMaps), "Google Maps")
        let german = AppText(language: .german)
        XCTAssertEqual(german.mapName(.appleMaps), "Apple Karten")
        XCTAssertEqual(german.mapName(.googleMaps), "Google Maps")
        let japanese = AppText(language: .japanese)
        XCTAssertEqual(japanese.mapName(.appleMaps), "Apple\u{30DE}\u{30C3}\u{30D7}")
        XCTAssertEqual(japanese.mapName(.googleMaps), "Google \u{30DE}\u{30C3}\u{30D7}")
        // Each choice is named differently in every language, so the two segments can be told apart
        for language in AppLanguage.allCases {
            let l = AppText(language: language)
            XCTAssertNotEqual(l.mapName(.appleMaps), l.mapName(.googleMaps), language.rawValue)
        }
    }

    /// The setting, its note and the three sentences about where the location goes name the button as the button says
    func testSentencesNameTheButtonAsItIs() {
        let keys = [
            "Open Directions in",
            "Directions opens the walking route from your starting point to a station. Google Maps opens in your default browser, and your starting point and the station are sent to Google.",
            "Your location is used to work out walking times. It's sent only to Apple Maps, for walking routes and place names, and nowhere else, unless you choose Google Maps for Directions. Nearby stations and walking times are kept on this Mac for the widget.",
            "Your location is used to work out walk times. It's sent only to Apple Maps, for walking routes and place names, and to no one else, unless you choose Google Maps for Directions. The transit data downloads don't include your location, though MTA Bus Time does see which nearby bus stops the app asks about. Nearby stations and walking times are kept on this Mac so the widget can show them, and the places you choose are saved only on this Mac.",
            "Finds stations near you and works out how long the walk takes. Your location is sent only to Apple Maps, unless you choose Google Maps for Directions.",
        ]
        for key in keys {
            XCTAssertTrue(AppText.allKeys.contains(key), key)
        }
        for language in AppLanguage.allCases {
            let l = AppText(language: language)
            let button = l.t("Directions")
            for key in keys {
                XCTAssertTrue(l.t(key).contains(button), "\(language.rawValue): \(key)")
            }
        }
    }
}

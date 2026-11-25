import XCTest
@testable import TransitCore

/// "Directions": which map, when the button is there, and the web addresses of the walk.
final class WalkingDirectionsTests: XCTestCase {
    let timesSquare = Coordinate(latitude: 40.758, longitude: -73.9855)
    let station = Coordinate(latitude: 40.7552931, longitude: -73.9876549)

    func testTheMapIsAppleMapsUntilAnotherIsChosen() {
        XCTAssertEqual(DirectionsMap.default, .appleMaps)
        XCTAssertEqual(DirectionsMap(stored: nil), .appleMaps)
        XCTAssertEqual(DirectionsMap(stored: "appleMaps"), .appleMaps)
        XCTAssertEqual(DirectionsMap(stored: "googleMaps"), .googleMaps)
        // A map only a later version knows, or anything else that isn't one: the default, not a crash or an empty choice
        XCTAssertEqual(DirectionsMap(stored: "someOtherMap"), .appleMaps)
        XCTAssertEqual(DirectionsMap(stored: ""), .appleMaps)
        // What is stored is the case's own name: renaming a case would lose the choice people made
        XCTAssertEqual(DirectionsMap.allCases.map(\.rawValue), ["appleMaps", "googleMaps"])
    }

    func testGoogleMapsAddressNamesBothEndsAndWalking() throws {
        let url = try XCTUnwrap(WalkingDirections.googleMapsURL(from: timesSquare, to: station))
        XCTAssertEqual(url.absoluteString,
                       "https://www.google.com/maps/dir/?api=1&origin=40.75800%2C-73.98550&destination=40.75529%2C-73.98765&travelmode=walking")
        // Read back the way a browser reads it: the origin is always there (without it Google starts from where the device is)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["api", "origin", "destination", "travelmode"])
        XCTAssertEqual(items.first { $0.name == "origin" }?.value, "40.75800,-73.98550")
        XCTAssertEqual(items.first { $0.name == "destination" }?.value, "40.75529,-73.98765")
        XCTAssertEqual(items.first { $0.name == "travelmode" }?.value, "walking")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.google.com")
    }

    func testAppleMapsLinkNamesBothEndsAndWalking() throws {
        let url = try XCTUnwrap(WalkingDirections.appleMapsURL(from: timesSquare, to: station))
        XCTAssertEqual(url.absoluteString, "https://maps.apple.com/?saddr=40.75800,-73.98550&daddr=40.75529,-73.98765&dirflg=w")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["saddr", "daddr", "dirflg"])
        XCTAssertEqual(url.host, "maps.apple.com")
    }

    func testNumbersAreWrittenTheSameEverywhere() {
        XCTAssertEqual(WalkingDirections.decimal(40.758), "40.75800")
        XCTAssertEqual(WalkingDirections.decimal(-73.9855), "-73.98550")
        // Rounded to about a metre, not cut
        XCTAssertEqual(WalkingDirections.decimal(40.7552931), "40.75529")
        XCTAssertEqual(WalkingDirections.decimal(40.755296), "40.75530")
        XCTAssertEqual(WalkingDirections.decimal(-73.9876549), "-73.98765")
        XCTAssertEqual(WalkingDirections.decimal(39.999996), "40.00000")
        // Small numbers keep their zeros, and nothing is ever "-0.00000"
        XCTAssertEqual(WalkingDirections.decimal(0.00042), "0.00042")
        XCTAssertEqual(WalkingDirections.decimal(-0.5), "-0.50000")
        XCTAssertEqual(WalkingDirections.decimal(-0.000001), "0.00000")
        XCTAssertEqual(WalkingDirections.decimal(0), "0.00000")
        XCTAssertEqual(WalkingDirections.decimal(-180), "-180.00000")
        // Only digits, one "." and a leading "-": no grouping, no comma for the decimals, no exponent
        for value in [40.758, -73.9855, 0.00001, -0.00001, 179.999999, -89.123456, 1e-9] {
            let text = WalkingDirections.decimal(value)
            XCTAssertNotNil(text.range(of: #"^-?[0-9]{1,3}\.[0-9]{5}$"#, options: .regularExpression), text)
        }
    }

    func testNoAddressForAPositionThatCantBeUsed() {
        let bad = [Coordinate(latitude: .nan, longitude: -73.98), Coordinate(latitude: 40.7, longitude: .infinity),
                   Coordinate(latitude: 91, longitude: -73.98), Coordinate(latitude: 40.7, longitude: -181),
                   Coordinate(latitude: 0, longitude: 0)]
        for position in bad {
            XCTAssertNil(WalkingDirections.googleMapsURL(from: position, to: station))
            XCTAssertNil(WalkingDirections.googleMapsURL(from: timesSquare, to: position))
            XCTAssertNil(WalkingDirections.appleMapsURL(from: position, to: station))
            XCTAssertNil(WalkingDirections.appleMapsURL(from: timesSquare, to: position))
            XCTAssertFalse(WalkingDirections.isOffered(networkAllowed: true, origin: position, destination: station))
            XCTAssertFalse(WalkingDirections.isOffered(networkAllowed: true, origin: timesSquare, destination: position))
        }
    }

    func testTheButtonIsThereOnlyWithTheNetworkAndBothEnds() {
        XCTAssertTrue(WalkingDirections.isOffered(networkAllowed: true, origin: timesSquare, destination: station))
        // The network turned off in Settings: opening a map would be going online
        XCTAssertFalse(WalkingDirections.isOffered(networkAllowed: false, origin: timesSquare, destination: station))
        // No starting point yet, or no station: nothing to open
        XCTAssertFalse(WalkingDirections.isOffered(networkAllowed: true, origin: nil, destination: station))
        XCTAssertFalse(WalkingDirections.isOffered(networkAllowed: true, origin: timesSquare, destination: nil))
    }
}

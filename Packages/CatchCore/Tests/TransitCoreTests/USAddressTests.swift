import XCTest
@testable import TransitCore

/// Place search keeps US suggestions only
final class USAddressTests: XCTestCase {
    func testKeepsUSPlaces() {
        XCTAssertTrue(USAddress.looksLikeUS(title: "Pickerington", subtitle: "Pickerington, OH 43147"))
        XCTAssertTrue(USAddress.looksLikeUS(title: "Hoboken Terminal", subtitle: "Hoboken, NJ"))
        XCTAssertTrue(USAddress.looksLikeUS(title: "Times Square", subtitle: "New York, NY, United States"))
        XCTAssertTrue(USAddress.looksLikeUS(title: "Search Nearby", subtitle: ""))
    }

    func testDropsOtherCountries() {
        XCTAssertFalse(USAddress.looksLikeUS(title: "London", subtitle: "London, UK"))
        XCTAssertFalse(USAddress.looksLikeUS(title: "Toronto", subtitle: "Toronto, ON, Canada"))
        XCTAssertFalse(USAddress.looksLikeUS(title: "San Juan", subtitle: "San Juan, PR, Puerto Rico"))
        XCTAssertFalse(USAddress.looksLikeUS(title: "Athens", subtitle: "Athens, Greece"))
        // A state code must stand alone, not start a longer word
        XCTAssertFalse(USAddress.looksLikeUS(title: "Kings Road", subtitle: "Chelsea, NYC Studios Ltd"))
    }

    /// Suggestions that arrive after the field was edited or cleared are for text it no longer shows, and aren't listed
    func testOnlySuggestionsForTheShownTextAreUsed() {
        XCTAssertTrue(USAddress.suggestionsAreCurrent(fragment: "Penn", query: "Penn"))
        for (fragment, query) in [("Penn", "P"), ("Penn", ""), ("Penn", "Pena"), ("P", "P")] {
            XCTAssertFalse(USAddress.suggestionsAreCurrent(fragment: fragment, query: query), "\(fragment) / \(query)")
        }
        XCTAssertFalse(USAddress.isSearchable(" a "))
        XCTAssertFalse(USAddress.isSearchable(""))
        XCTAssertTrue(USAddress.isSearchable("ab"))
    }

    /// "No places in the United States were found" goes by the results only: said when every result was elsewhere, or when a long
    /// enough text found nothing; not while the first letters are typed, and never when a US place was found
    func testSaysNothingFoundOnlyFromTheResults() {
        XCTAssertTrue(USAddress.saysNothingFound(kept: 0, found: 3, for: "Lo"), "Results, all elsewhere")
        XCTAssertTrue(USAddress.saysNothingFound(kept: 0, found: 0, for: "Xyzzy"))
        XCTAssertTrue(USAddress.saysNothingFound(kept: 0, found: 0, for: "abc"))
        XCTAssertFalse(USAddress.saysNothingFound(kept: 0, found: 0, for: "ab"), "Still being typed")
        XCTAssertFalse(USAddress.saysNothingFound(kept: 0, found: 0, for: "  ab  "), "Spaces don't count")
        XCTAssertFalse(USAddress.saysNothingFound(kept: 1, found: 4, for: "Penn"))
        XCTAssertFalse(USAddress.saysNothingFound(kept: 2, found: 2, for: "Pe"))
    }

    /// A name with its town after a comma that finds nothing is asked again without the town, one part at a time
    func testATextThatFindsNothingIsAskedAgainWithoutItsLastPart() {
        XCTAssertEqual(SearchRetry.simpler("Springfield Union Station, Springfield MA"), "Springfield Union Station")
        XCTAssertEqual(SearchRetry.simpler("1 Main St, Springfield, MA"), "1 Main St, Springfield")
        XCTAssertNil(SearchRetry.simpler("Springfield Union Station"), "No comma")
        XCTAssertNil(SearchRetry.simpler("Springfield Union Station, "), "Nothing after the comma: still being typed")
        XCTAssertNil(SearchRetry.simpler("ab, Springfield"), "Too little left")

        let typed = "1 Main St, Springfield, MA"
        var retry = SearchRetry()
        XCTAssertEqual(retry.leftOut, "")
        XCTAssertEqual(retry.next(after: typed, query: typed), "1 Main St, Springfield")
        XCTAssertEqual(retry.leftOut, ", MA")
        XCTAssertEqual(retry.next(after: "1 Main St, Springfield", query: typed), "1 Main St")
        XCTAssertEqual(retry.leftOut, ", Springfield, MA")
        XCTAssertNil(retry.next(after: "1 Main St", query: typed), "Nothing simpler is left")
        XCTAssertNil(retry.next(after: "Something else, NJ", query: typed), "Not the text asked")
    }

    /// Results count for the text the field shows, as typed or as the simpler text asked for it; an edit makes both stale
    func testResultsForTheSimplerTextCountOnlyForTheTextItWasAskedFor() {
        let typed = "Springfield Union Station, Springfield MA"
        var retry = SearchRetry()
        XCTAssertTrue(retry.isCurrent(fragment: typed, query: typed))
        XCTAssertFalse(retry.isCurrent(fragment: "Springfield Union Station", query: typed), "Not asked yet")
        XCTAssertEqual(retry.next(after: typed, query: typed), "Springfield Union Station")
        XCTAssertTrue(retry.isCurrent(fragment: "Springfield Union Station", query: typed))
        XCTAssertTrue(retry.isCurrent(fragment: typed, query: typed))
        XCTAssertFalse(retry.isCurrent(fragment: "Springfield Union Station", query: typed + "x"), "The field was edited")
        XCTAssertFalse(retry.isCurrent(fragment: "Springfield Union Station", query: ""), "The field was cleared")
        retry.reset()
        XCTAssertFalse(retry.isCurrent(fragment: "Springfield Union Station", query: typed), "After a reset")
        XCTAssertEqual(retry.leftOut, "")
        XCTAssertFalse(SearchRetry().isCurrent(fragment: "P", query: "P"), "Too short to search")
    }

    /// The results of the simpler text: the ones that mention what was left out come first, the others keep their order
    func testResultsThatMentionThePartLeftOutComeFirst() {
        let found = [
            "Springfield Union Station, Springfield, IL, United States",
            "Union Station, Washington, DC, United States",
            "Springfield Union Station, 55 Frank B Murray St, Springfield, MA 01103, United States",
            "Springfield Station, Springfield, MA, United States",
        ]
        var retry = SearchRetry()
        XCTAssertEqual(retry.listed(found) { $0 }, found, "Asked as typed: the order they came in")
        let typed = "Union Station, Springfield MA"
        XCTAssertEqual(retry.next(after: typed, query: typed), "Union Station")
        XCTAssertEqual(retry.listed(found) { $0 }, [found[2], found[3], found[0], found[1]])
        // A word counts whole and once: "ma" isn't found in "Main", and a town named twice isn't worth more
        XCTAssertEqual(retry.listed(["Main St, Springfield, IL", "Elm St, Boston, MA"]) { $0 },
                       ["Main St, Springfield, IL", "Elm St, Boston, MA"])
        XCTAssertEqual(retry.listed(Array(1...20).map { "Place \($0)" }) { $0 }.count, SearchRetry.listedAtMost)
        XCTAssertEqual(SearchRetry().listed(Array(1...20)) { "\($0)" }, Array(1...8))
        // One place given twice (Springfield Union Station, both "Springfield, MA, United States"): listed once
        let twice = ["Springfield Union Station, Springfield, MA, United States", "Springfield Union Station, Springfield, MA, United States",
                     "Springfield Union Station, 55 Frank B Murray St, Springfield, MA 01103, United States"]
        XCTAssertEqual(SearchRetry().listed(twice) { $0 }, [twice[0], twice[2]])
    }
}

/// A list inside another scrolling area keeps the scroll gestures that start over it
final class InnerScrollTests: XCTestCase {
    func testAGestureIsPassedOnOnlyWhenTheListIsAtItsEndThatWay() {
        // 200 pt of rows beyond what shows
        XCTAssertTrue(InnerScroll.isAtItsEnd(offset: 0, most: 200, delta: 3), "At the top, scrolling up")
        XCTAssertFalse(InnerScroll.isAtItsEnd(offset: 0, most: 200, delta: -3), "At the top, scrolling down")
        XCTAssertTrue(InnerScroll.isAtItsEnd(offset: 200, most: 200, delta: -3), "At the bottom, scrolling down")
        XCTAssertTrue(InnerScroll.isAtItsEnd(offset: 199.6, most: 200, delta: -3), "Within a point of the bottom")
        XCTAssertFalse(InnerScroll.isAtItsEnd(offset: 200, most: 200, delta: 3))
        XCTAssertFalse(InnerScroll.isAtItsEnd(offset: 80, most: 200, delta: 3), "In the middle")
        XCTAssertFalse(InnerScroll.isAtItsEnd(offset: 80, most: 200, delta: -3))
        XCTAssertFalse(InnerScroll.isAtItsEnd(offset: 0, most: 200, delta: 0), "No direction yet")
        // Everything fits: the list doesn't scroll, so the area around it does
        XCTAssertFalse(InnerScroll.isAtItsEnd(offset: 0, most: 0, delta: 3))
        XCTAssertFalse(InnerScroll.isAtItsEnd(offset: 0, most: 0, delta: -3))
    }

    func testAGestureIsDecidedWhenItStarts() {
        var gesture = InnerScroll.Gesture()
        // Starts over the list at its bottom: dropped, and so is the rest of it, wherever the pointer and the list are then
        XCTAssertTrue(gesture.drops(starts: true, over: true, offset: 200, most: 200, delta: -2))
        XCTAssertTrue(gesture.drops(starts: false, over: true, offset: 200, most: 200, delta: -9))
        XCTAssertTrue(gesture.drops(starts: false, over: false, offset: 200, most: 200, delta: 4))
        // The next one starts in the list's middle: it scrolls the list, also once it reaches the end
        XCTAssertFalse(gesture.drops(starts: true, over: true, offset: 120, most: 200, delta: -2))
        XCTAssertFalse(gesture.drops(starts: false, over: true, offset: 200, most: 200, delta: -9))
        // Not over the list: the area around it scrolls
        XCTAssertFalse(gesture.drops(starts: true, over: false, offset: 200, most: 200, delta: -2))
        // A mouse wheel: each step is its own gesture
        XCTAssertTrue(gesture.drops(starts: true, over: true, offset: 0, most: 200, delta: 1))
        XCTAssertFalse(gesture.drops(starts: true, over: true, offset: 0, most: 200, delta: -1))
    }
}

/// Where walking starts from: never a place nobody chose
final class StartingPlaceTests: XCTestCase {
    func place(current: Bool, position: Bool = false, failed: Bool = false, chosen: Bool) -> StartingPlace {
        StartingPlace.of(usesCurrentLocation: current, hasPosition: position, locationFailed: failed, hasChosenPlace: chosen)
    }

    func testAChosenPlaceIsUsedWhenAskedForOrWhenLocationFails() {
        XCTAssertEqual(place(current: false, chosen: true), .chosen)
        XCTAssertEqual(place(current: false, position: true, chosen: true), .chosen, "A position isn't used with a chosen place")
        XCTAssertEqual(place(current: true, position: true, chosen: true), .current)
        XCTAssertEqual(place(current: true, chosen: true), .locating)
        XCTAssertEqual(place(current: true, failed: true, chosen: true), .chosenFallback)
        XCTAssertEqual(place(current: true, position: true, failed: true, chosen: true), .current, "A position still known wins")
    }

    /// No built-in place stands in: there is none until a place is chosen or a position found
    func testWithoutAChosenPlaceAndWithoutLocationThereIsNone() {
        XCTAssertEqual(place(current: true, failed: true, chosen: false), .missing)
        XCTAssertEqual(place(current: false, chosen: false), .missing)
        XCTAssertEqual(place(current: false, position: true, chosen: false), .missing)
        XCTAssertEqual(place(current: true, chosen: false), .locating, "Still being found: not missing yet")
        XCTAssertEqual(place(current: true, position: true, chosen: false), .current)
    }

    /// A position too far off to find the stations nearby is its own case: neither the current location nor the chosen place
    /// (that may be far from here), and never "no place chosen yet"
    func testATooApproximatePositionIsNotUsed() {
        func place(chosen: Bool, failed: Bool = false) -> StartingPlace {
            StartingPlace.of(usesCurrentLocation: true, hasPosition: true, positionTooApproximate: true, locationFailed: failed,
                             hasChosenPlace: chosen)
        }
        XCTAssertEqual(place(chosen: false), .tooApproximate)
        XCTAssertEqual(place(chosen: true), .tooApproximate)
        XCTAssertEqual(place(chosen: true, failed: true), .tooApproximate)
        // Only the current location's position counts
        XCTAssertEqual(StartingPlace.of(usesCurrentLocation: false, hasPosition: true, positionTooApproximate: true, locationFailed: false,
                                        hasChosenPlace: true), .chosen)
        XCTAssertEqual(StartingPlace.of(usesCurrentLocation: true, hasPosition: false, positionTooApproximate: true, locationFailed: false,
                                        hasChosenPlace: true), .locating)
    }

    /// macOS's horizontal accuracy in meters: fine up to 300, approximate up to 3,000, too approximate beyond; unknown is fine
    func testLocationAccuracySteps() {
        XCTAssertEqual(LocationAccuracy.of(meters: nil), .fine)
        XCTAssertEqual(LocationAccuracy.of(meters: -1), .fine, "macOS doesn't know")
        XCTAssertEqual(LocationAccuracy.of(meters: 0), .fine)
        XCTAssertEqual(LocationAccuracy.of(meters: 65), .fine)
        XCTAssertEqual(LocationAccuracy.of(meters: 300), .fine)
        XCTAssertEqual(LocationAccuracy.of(meters: 301), .approximate)
        XCTAssertEqual(LocationAccuracy.of(meters: 1500), .approximate)
        XCTAssertEqual(LocationAccuracy.of(meters: 3000), .approximate)
        XCTAssertEqual(LocationAccuracy.of(meters: 3001), .tooApproximate)
        XCTAssertEqual(LocationAccuracy.of(meters: 20000), .tooApproximate)
    }

    /// Turning "Use my location" off leaves "A place I choose": with a place chosen before, that place; with none, the picker opens
    func testTurningLocationOffOpensThePickerOnlyWhenNoPlaceWasChosen() {
        // What's missing when there is no starting place: a choice, or the location (off, or tried without a position)
        XCTAssertEqual(StartingPlace.missingReason(usesCurrentLocation: false, locationDenied: false), .notChosen)
        XCTAssertEqual(StartingPlace.missingReason(usesCurrentLocation: false, locationDenied: true), .notChosen)
        XCTAssertEqual(StartingPlace.missingReason(usesCurrentLocation: true, locationDenied: true), .locationOff)
        XCTAssertEqual(StartingPlace.missingReason(usesCurrentLocation: true, locationDenied: false), .locationFailed)
        XCTAssertFalse(StartingPlace.opensPicker(usesCurrentLocation: false, hasChosenPlace: true))
        XCTAssertTrue(StartingPlace.opensPicker(usesCurrentLocation: false, hasChosenPlace: false))
        // With the current location wanted, the empty page's button is enough: location may come back
        XCTAssertFalse(StartingPlace.opensPicker(usesCurrentLocation: true, hasChosenPlace: false))
    }
}

/// A slow address lookup never replaces a newer choice
final class PlaceLookupGateTests: XCTestCase {
    func testCurrentLookupIsUsedOnce() {
        var gate = PlaceLookupGate()
        XCTAssertFalse(gate.isPending)
        let a = gate.start()
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.finish(a))
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.finish(a))
    }

    // Suggestion A, then suggestion B: only B is used, whichever comes back first
    func testNewerLookupMakesOlderOneStale() {
        var gate = PlaceLookupGate()
        let a = gate.start()
        let b = gate.start()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(gate.finish(a))
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.finish(b))

        let c = gate.start()
        let d = gate.start()
        XCTAssertTrue(gate.finish(d))
        XCTAssertFalse(gate.finish(c))
        XCTAssertFalse(gate.isPending)
    }

    // A favorite, Clear, an edit of the search text or Cancel while A is in flight: A is ignored, found or not
    func testDropMakesLookupStale() {
        var gate = PlaceLookupGate()
        let a = gate.start()
        gate.drop()
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.finish(a))
        // Dropping with nothing in flight changes nothing, and the next lookup still counts
        gate.drop()
        let b = gate.start()
        XCTAssertFalse(gate.finish(a))
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.finish(b))
    }

    // Reopened: start over only a computation that closing stopped; a lookup in flight starts one itself when it lands
    func testRestartWhenReopened() {
        var gate = PlaceLookupGate()
        XCTAssertTrue(gate.needsRestart(hasPlace: true, loading: true))
        XCTAssertFalse(gate.needsRestart(hasPlace: true, loading: false))
        XCTAssertFalse(gate.needsRestart(hasPlace: false, loading: true))
        let a = gate.start()
        XCTAssertFalse(gate.needsRestart(hasPlace: true, loading: true))
        XCTAssertFalse(gate.needsRestart(hasPlace: false, loading: false))
        XCTAssertTrue(gate.finish(a))
        XCTAssertTrue(gate.needsRestart(hasPlace: true, loading: true))
    }
}

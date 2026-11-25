import XCTest
@testable import TransitCore
#if canImport(MapKit)
import MapKit
#endif

final class SubwayMapTests: XCTestCase {

    func testBundledMapLoads() throws {
        let map = try SubwayMap.loadBundled()
        XCTAssertGreaterThan(map.stations.count, 400)
        XCTAssertTrue(map.routes.contains { $0.route == "7" && $0.color.count == 6 })
        XCTAssertTrue(map.routes.allSatisfy { !$0.lines.isEmpty })
        // Nearest station around 61 St-Woodside
        let near = map.nearestStation(to: Coordinate(latitude: 40.74563, longitude: -73.90297))
        XCTAssertEqual(near?.station.name, "61 St-Woodside")
    }

    func testRoundTrip() throws {
        let map = try SubwayMap.loadBundled()
        XCTAssertEqual(try SubwayMap.decode(map.encoded()), map)
    }

    /// The 1st of each month where this Mac is, in every area: the check is the app's own
    func testMonthlyCheckOnFirstOfMonth() {
        let cal = SubwayMapSchedule.calendar
        XCTAssertEqual(cal.timeZone.identifier, TimeZone.current.identifier)
        func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 12) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: day, hour: h))!
        }
        XCTAssertTrue(SubwayMapSchedule.isDue(lastChecked: nil, now: d(2026, 10, 13)))
        // Already checked this month: no check
        XCTAssertFalse(SubwayMapSchedule.isDue(lastChecked: d(2026, 10, 1, 0), now: d(2026, 10, 31, 23)))
        // Checked on the last day of last month: due on the 1st
        XCTAssertTrue(SubwayMapSchedule.isDue(lastChecked: d(2026, 9, 30, 23), now: d(2026, 10, 1, 0)))
        XCTAssertEqual(SubwayMapSchedule.nextCheck(after: d(2026, 10, 13)), d(2026, 11, 1, 0))
        XCTAssertEqual(SubwayMapSchedule.nextCheck(after: d(2026, 12, 20)), d(2027, 1, 1, 0))
    }

    func testBuilderFromSmallFeed() throws {
        let files: [String: Data] = [
            "routes.txt": Data("route_id,route_short_name,route_color\n7,7,B933AD\nG,G,\n".utf8),
            "trips.txt": Data("route_id,trip_id,shape_id\n7,t1,7..N97R\n7,t2,7..S97R\nG,t3,G..N01R\n".utf8),
            "shapes.txt": Data("""
            shape_id,shape_pt_sequence,shape_pt_lat,shape_pt_lon
            7..N97R,0,40.0,-73.0
            7..N97R,1,40.0000001,-72.99
            7..N97R,2,40.0,-72.98
            7..S97R,0,40.0,-72.98
            7..S97R,1,40.0,-73.0
            G..N01R,0,40.1,-73.1
            G..N01R,1,40.2,-73.1

            """.utf8),
            "stops.txt": Data("stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station\n712,\"61 St-Woodside\",40.745630,-73.902984,1,\n712N,61 St-Woodside,40.745630,-73.902984,,712\n".utf8),
            "feed_info.txt": Data("feed_publisher_name,feed_version\nMTA,v1\n".utf8),
        ]
        let map = try SubwayMapBuilder.build(files: files)
        XCTAssertEqual(map.feedVersion, "v1")
        XCTAssertEqual(map.stations.map(\.name), ["61 St-Woodside"])
        XCTAssertEqual(map.routes.map(\.route), ["7", "G"])
        XCTAssertEqual(map.routes[1].color, "808183")
        // Only northbound; points almost on a straight line in the middle are simplified away
        XCTAssertEqual(map.routes[0].lines, [[[40.0, -73.0], [40.0, -72.98]]])
    }

    /// Built from the full MTA data and compared with the bundled file (runs only when CMT_GTFS_DIR is set).
    func testBuilderMatchesBundledFile() throws {
        guard let dir = ProcessInfo.processInfo.environment["CMT_GTFS_DIR"] else {
            throw XCTSkip("CMT_GTFS_DIR not set")
        }
        var files: [String: Data] = [:]
        for name in ["routes.txt", "trips.txt", "shapes.txt", "stops.txt", "feed_info.txt"] {
            files[name] = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let built = try SubwayMapBuilder.build(files: files)
        let bundled = try SubwayMap.loadBundled()
        // Python and Swift round the 5th decimal place slightly differently, so allow a difference of 0.00001
        XCTAssertEqual(built.stations.map(\.id), bundled.stations.map(\.id))
        for (a, b) in zip(built.stations, bundled.stations) {
            XCTAssertEqual(a.lat, b.lat, accuracy: 0.0000101)
            XCTAssertEqual(a.lon, b.lon, accuracy: 0.0000101)
        }
        XCTAssertEqual(built.routes.map(\.route), bundled.routes.map(\.route))
        XCTAssertEqual(built.routes.map { $0.lines.map(\.count) }, bundled.routes.map { $0.lines.map(\.count) })
    }

    /// One operator failing doesn't count the month as checked or download the others again; it's retried alone, waiting longer each time
    func testMonthlyCheckRetriesOnlyTheFailedOperator() {
        let all: Set<String> = ["A", "B", "C"]
        let last = Date(timeIntervalSince1970: 1_790_000_000)   // a September check
        let now = Date(timeIntervalSince1970: 1_791_993_600)    // 2026-10-14
        var check = MonthlyCheck()
        XCTAssertEqual(check.remaining(of: all, lastChecked: last, now: now), all)
        check.failed(["B"], now: now)
        XCTAssertFalse(check.refreshed(["A", "C"], of: all, lastChecked: last, now: now))
        XCTAssertTrue(check.hasFailures)
        // B waits 10 minutes, then 20 after a second failure
        XCTAssertEqual(check.remaining(of: all, lastChecked: last, now: now.addingTimeInterval(599)), [])
        XCTAssertEqual(check.remaining(of: all, lastChecked: last, now: now.addingTimeInterval(600)), ["B"])
        let second = now.addingTimeInterval(600)
        check.failed(["B"], now: second)
        XCTAssertEqual(check.remaining(of: all, lastChecked: last, now: second.addingTimeInterval(1199)), [])
        XCTAssertEqual(check.remaining(of: all, lastChecked: last, now: second.addingTimeInterval(1200)), ["B"])
        // B gets through: the month is checked
        XCTAssertTrue(check.refreshed(["B"], of: all, lastChecked: last, now: second.addingTimeInterval(1200)))
        XCTAssertFalse(check.hasFailures)
        // Every operator failing (offline) doesn't count either; a new month starts over
        var offline = MonthlyCheck()
        offline.failed(all, now: now)
        XCTAssertFalse(offline.refreshed([], of: all, lastChecked: last, now: now))
        XCTAssertEqual(offline.remaining(of: all, lastChecked: last, now: now.addingTimeInterval(600)), all)
        var partial = MonthlyCheck()
        _ = partial.refreshed(["A"], of: all, lastChecked: last, now: now)
        XCTAssertEqual(partial.remaining(of: all, lastChecked: last, now: now), ["B", "C"])
        XCTAssertEqual(partial.remaining(of: all, lastChecked: last, now: now.addingTimeInterval(30 * 86400)), all)
        // The longest wait is a day
        var stuck = MonthlyCheck()
        for _ in 0..<12 { stuck.failed(["A"], now: now) }
        XCTAssertTrue(stuck.canRetry("A", now: now.addingTimeInterval(24 * 3600)))
        // The source list moved an address: no more waiting, and what this month's check already got stays done
        _ = stuck.refreshed(["B"], of: all, lastChecked: last, now: now)
        stuck.forgetFailures()
        XCTAssertFalse(stuck.hasFailures)
        XCTAssertEqual(stuck.remaining(of: all, lastChecked: last, now: now), ["A", "C"])
    }

    /// An operator that already downloaded fine since the month began (saved, so after a relaunch too) isn't downloaded again by the
    /// month's check, and counts toward finishing it; one downloaded last month still is
    func testMonthlyCheckCountsOperatorsDownloadedThisMonth() {
        let all: Set<String> = ["A", "B", "C"]
        let last = Date(timeIntervalSince1970: 1_790_000_000)   // a September check
        let now = Date(timeIntervalSince1970: 1_791_993_600)    // 2026-10-14
        let thisMonth = SubwayMapSchedule.startOfMonth(now)
        let saved: [String: Date] = ["A": thisMonth.addingTimeInterval(3600), "B": thisMonth.addingTimeInterval(-3600)]
        var check = MonthlyCheck()
        XCTAssertEqual(check.remaining(of: all, lastChecked: last, now: now, downloaded: saved), ["B", "C"])
        XCTAssertFalse(check.refreshed(["B"], of: all, lastChecked: last, now: now, downloaded: saved))
        XCTAssertEqual(check.remaining(of: all, lastChecked: last, now: now, downloaded: saved), ["C"])
        XCTAssertTrue(check.refreshed(["C"], of: all, lastChecked: last, now: now, downloaded: saved))
        // Every operator already downloaded this month: the month is checked without downloading anything
        var done = MonthlyCheck()
        let allSaved = Dictionary(uniqueKeysWithValues: all.map { ($0, thisMonth.addingTimeInterval(60)) })
        XCTAssertEqual(done.remaining(of: all, lastChecked: last, now: now, downloaded: allSaved), [])
        XCTAssertTrue(done.refreshed([], of: all, lastChecked: last, now: now, downloaded: allSaved))
        // Without the saved days, as before
        XCTAssertEqual(MonthlyCheck().remaining(of: all, lastChecked: last, now: now), all)
    }

    // MARK: Walking-time labels beside the stations in range

    private let labelSize = MapLabelLayout.Size(width: 100, height: 30)
    private let minutesSize = MapLabelLayout.Size(width: 44, height: 16)
    private let mapBounds = MapLabelLayout.Box(x: 0, y: 0, width: 600, height: 400)

    private func item(_ id: String, _ x: Double, _ y: Double) -> MapLabelLayout.Item {
        MapLabelLayout.Item(id: id, x: x, y: y, full: labelSize, compact: minutesSize)
    }

    func testLabelGoesBesideTheStation() {
        let ltr = MapLabelLayout.place([item("a", 300, 200)], in: mapBounds, gap: 10, rightToLeft: false)
        XCTAssertEqual(ltr.map(\.side), [.right])
        XCTAssertEqual(ltr.first?.box, MapLabelLayout.Box(x: 310, y: 185, width: 100, height: 30))
        XCTAssertEqual(ltr.first?.compact, false)
        // Pinning this point of the label to the station puts the label in its box
        XCTAssertEqual(ltr.first?.anchorX ?? 0, -0.1, accuracy: 1e-9)
        XCTAssertEqual(ltr.first?.anchorY ?? 0, 0.5, accuracy: 1e-9)
        // Right to left: the left side first
        let rtl = MapLabelLayout.place([item("a", 300, 200)], in: mapBounds, gap: 10, rightToLeft: true)
        XCTAssertEqual(rtl.map(\.side), [.left])
        XCTAssertEqual(rtl.first?.box.maxX, 290)
        XCTAssertEqual(rtl.first?.anchorX ?? 0, 1.1, accuracy: 1e-9)
    }

    func testNearestStationTakesThePlaceFirstAndLabelsNeverOverlap() {
        // Two stations in the same spot: the first one in the list (the nearer) gets the right side, the next one the left
        let two = MapLabelLayout.place([item("near", 300, 200), item("far", 300, 200)], in: mapBounds, gap: 10, rightToLeft: false)
        XCTAssertEqual(two.map(\.id), ["near", "far"])
        XCTAssertEqual(two.map(\.side), [.right, .left])
        // A crowd: not all fit; the ones that do never touch each other, stay on the map and keep the list's order
        let crowd = (0..<12).map { item("s\($0)", 280 + Double($0 % 4) * 14, 180 + Double($0 / 4) * 14) }
        let placed = MapLabelLayout.place(crowd, in: mapBounds, gap: 10, rightToLeft: false)
        XCTAssertFalse(placed.isEmpty)
        XCTAssertLessThan(placed.count, crowd.count)
        for (i, a) in placed.enumerated() {
            XCTAssertTrue(mapBounds.contains(a.box))
            for b in placed[(i + 1)...] {
                XCTAssertFalse(a.box.touches(b.box), "\(a.id) and \(b.id)")
            }
        }
        let ids = placed.map(\.id)
        XCTAssertEqual(ids, crowd.map(\.id).filter(ids.contains))
    }

    func testMinutesOnlyWhenTheNameDoesNotFitThenNoLabel() {
        // A small map: the label with the name fits on no side, the minutes alone do
        let small = MapLabelLayout.Box(x: 0, y: 0, width: 110, height: 60)
        let one = MapLabelLayout.place([item("a", 55, 30)], in: small, gap: 6, rightToLeft: false)
        XCTAssertEqual(one.map(\.side), [.right])
        XCTAssertEqual(one.first?.compact, true)
        XCTAssertEqual(one.first?.box.width, 44)
        // Smaller still: no label (the station keeps its ring on the map)
        let tiny = MapLabelLayout.Box(x: 0, y: 0, width: 40, height: 14)
        XCTAssertTrue(MapLabelLayout.place([item("a", 20, 7)], in: tiny, gap: 6, rightToLeft: false).isEmpty)
    }

    func testLabelsKeepClearOfButtonsOtherStationsAndTheEdge() {
        // The buttons to the right of the station: the label goes left
        let buttons = MapLabelLayout.Box(x: 320, y: 195, width: 200, height: 60)
        let left = MapLabelLayout.place([item("a", 300, 200)], in: mapBounds, keepClear: [buttons], gap: 10, rightToLeft: false)
        XCTAssertEqual(left.map(\.side), [.left])
        // Another station in range on the left as well, and below is blocked by the buttons: above, then, where the other dot of its
        // own complex is (a complex has several), so moved up past that dot
        let sibling = MapLabelLayout.Box(x: 330, y: 160, width: 16, height: 16)
        let dots = ["a": [MapLabelLayout.Box(x: 292, y: 192, width: 16, height: 16), sibling],
                    "b": [MapLabelLayout.Box(x: 220, y: 192, width: 16, height: 16)]]
        let above = MapLabelLayout.place([item("a", 300, 200)], in: mapBounds, keepClear: [buttons], dots: dots,
                                         gap: 10, rightToLeft: false)
        XCTAssertEqual(above.map(\.side), [.above])
        XCTAssertEqual(above.first?.box, MapLabelLayout.Box(x: 250, y: 128, width: 100, height: 30))
        XCTAssertFalse(above.first.map { $0.box.touches(sibling) } ?? true)
        // Near the right edge of the map: the left side
        let edge = MapLabelLayout.place([item("a", 560, 200)], in: mapBounds, gap: 10, rightToLeft: false)
        XCTAssertEqual(edge.map(\.side), [.left])
        // A station off the map gets no label
        XCTAssertTrue(MapLabelLayout.place([item("a", 700, 200)], in: mapBounds, gap: 10, rightToLeft: false).isEmpty)
    }

    func testLabelsKeepClearOfTheirOwnStationsOtherDotsWhenThereIsRoom() {
        let own = MapLabelLayout.Box(x: 292, y: 192, width: 16, height: 16)
        // Another dot of the same complex to the right: the label goes left instead of covering it
        let right = MapLabelLayout.Box(x: 340, y: 192, width: 16, height: 16)
        let left = MapLabelLayout.place([item("a", 300, 200)], in: mapBounds, dots: ["a": [own, right]], gap: 10, rightToLeft: false)
        XCTAssertEqual(left.map(\.side), [.left])
        XCTAssertEqual(left.first?.compact, false)
        // Its dots on every side: the first side still, moved out past its dot there, so it stands beside the whole complex
        let around = [own, right, MapLabelLayout.Box(x: 240, y: 192, width: 16, height: 16),
                      MapLabelLayout.Box(x: 292, y: 165, width: 16, height: 16), MapLabelLayout.Box(x: 292, y: 222, width: 16, height: 16)]
        let beside = MapLabelLayout.place([item("a", 300, 200)], in: mapBounds, dots: ["a": around], gap: 10, rightToLeft: false)
        XCTAssertEqual(beside.map(\.side), [.right])
        XCTAssertEqual(beside.first?.box, MapLabelLayout.Box(x: 358, y: 185, width: 100, height: 30))
        XCTAssertEqual(beside.first?.compact, false)
        XCTAssertEqual(beside.first?.anchorX ?? 0, -0.58, accuracy: 1e-9)
        // Right to left: the left side first, past its dot there
        let rtl = MapLabelLayout.place([item("a", 300, 200)], in: mapBounds, dots: ["a": around], gap: 10, rightToLeft: true)
        XCTAssertEqual(rtl.map(\.side), [.left])
        XCTAssertEqual(rtl.first?.box.maxX, 238)
        // Never moved out past another station's dot (the label would look like that station's): with one beyond its dot on the
        // right, the left side
        let other = MapLabelLayout.place([item("a", 300, 200)], in: mapBounds,
                                         dots: ["a": around, "b": [MapLabelLayout.Box(x: 330, y: 186, width: 16, height: 16)]],
                                         gap: 10, rightToLeft: false)
        XCTAssertEqual(other.map(\.side), [.left])
        XCTAssertEqual(other.first?.box.maxX, 238)
        // No room past them, nor beside its other dots, anywhere (the map ends there): the whole label still goes on the first side,
        // over one of its own station's dots, rather than the minutes only
        let tight = MapLabelLayout.Box(x: 180, y: 160, width: 240, height: 80)
        let covering = MapLabelLayout.place([item("a", 300, 200)], in: tight, dots: ["a": around], gap: 10, rightToLeft: false)
        XCTAssertEqual(covering.map(\.side), [.right])
        XCTAssertEqual(covering.first?.box, MapLabelLayout.Box(x: 310, y: 185, width: 100, height: 30))
        XCTAssertEqual(covering.first?.compact, false)
    }

    func testLabelMovesOutPastItsOwnComplexOnlyALittle() {
        let own = MapLabelLayout.Box(x: 292, y: 192, width: 16, height: 16)
        let blocked = [own, MapLabelLayout.Box(x: 240, y: 192, width: 16, height: 16),
                       MapLabelLayout.Box(x: 292, y: 165, width: 16, height: 16), MapLabelLayout.Box(x: 292, y: 222, width: 16, height: 16)]
        // A row of its dots to the right, longer than maxSlide: not past those, but past the one on the left
        let row = (0..<4).map { MapLabelLayout.Box(x: 340 + Double($0) * 18, y: 192, width: 16, height: 16) }
        let left = MapLabelLayout.place([item("a", 300, 200)], in: mapBounds, dots: ["a": blocked + row], gap: 10, rightToLeft: false)
        XCTAssertEqual(left.map(\.side), [.left])
        XCTAssertEqual(left.first?.box.maxX, 238)
        // Never past another label either: a nearer station's small label is between this one's dot and its other dot on the right
        let near = MapLabelLayout.Item(id: "near", x: 302, y: 200, full: MapLabelLayout.Size(width: 30, height: 14),
                                       compact: MapLabelLayout.Size(width: 20, height: 14))
        let labels = MapLabelLayout.place([near, item("a", 300, 200)], in: mapBounds,
                                          dots: ["a": blocked + [MapLabelLayout.Box(x: 350, y: 192, width: 16, height: 16)]],
                                          gap: 10, rightToLeft: false)
        XCTAssertEqual(labels.map(\.id), ["near", "a"])
        XCTAssertEqual(labels.map(\.side), [.right, .left])
        XCTAssertEqual(labels.last?.box.maxX, 238)
    }

    func testLabelGoesBesideAnotherDotOfItsComplexWhenItsOwnIsBoxedIn() {
        // A complex spread out to the lower right of the dot the label stands beside. Other labels and the buttons (kept clear)
        // leave no room on its left or above, nor moved out past its other dots to the right or below
        let own = MapLabelLayout.Box(x: 292, y: 192, width: 16, height: 16)
        let middle = MapLabelLayout.Box(x: 327, y: 207, width: 16, height: 16)
        let far = MapLabelLayout.Box(x: 339, y: 214, width: 16, height: 16)
        let clear = [MapLabelLayout.Box(x: 150, y: 150, width: 210, height: 38),
                     MapLabelLayout.Box(x: 200, y: 245, width: 120, height: 30)]
        for rightToLeft in [false, true] {
            let labels = MapLabelLayout.place([item("a", 300, 200)], in: mapBounds, keepClear: clear, dots: ["a": [own, middle, far]],
                                              gap: 10, rightToLeft: rightToLeft)
            // Beside the far dot, clear of all three
            XCTAssertEqual(labels.map(\.side), [.right])
            XCTAssertEqual(labels.first?.box, MapLabelLayout.Box(x: 357, y: 207, width: 100, height: 30))
            XCTAssertEqual(labels.first?.compact, false)
            XCTAssertEqual(labels.first?.anchorX ?? 0, -0.57, accuracy: 1e-9)
            for dot in [own, middle, far] {
                XCTAssertFalse(labels.first.map { $0.box.touches(dot) } ?? true)
            }
        }
        // Another station's dot there: not beside the far dot either, so the label goes over its own complex's dots, as before
        let other = MapLabelLayout.Box(x: 400, y: 215, width: 16, height: 16)
        let covering = MapLabelLayout.place([item("a", 300, 200)], in: mapBounds, keepClear: clear,
                                            dots: ["a": [own, middle, far], "b": [other]], gap: 10, rightToLeft: false)
        XCTAssertEqual(covering.map(\.side), [.below])
        XCTAssertEqual(covering.first?.box, MapLabelLayout.Box(x: 250, y: 210, width: 100, height: 30))
    }

    func testStationDotsInRangeStopGrowingWhenZoomedIn() {
        // Zoomed out: in meters, as before (a 45 m dot is 9 points across at 10 m a point)
        XCTAssertFalse(MapDotSize.isFixed(metersPerPoint: 40))
        XCTAssertFalse(MapDotSize.isFixed(metersPerPoint: 5))
        XCTAssertEqual(MapDotSize.diameter(45, metersPerPoint: 10), 9, accuracy: 1e-9)
        // Zoomed in: a fixed 18 points across whatever the zoom, so two stations 40 m apart come apart as you zoom in
        for mpp in [4.9, 3.0, 1.9, 1.0, 0.5] {
            XCTAssertTrue(MapDotSize.isFixed(metersPerPoint: mpp), "at \(mpp) m a point")
            XCTAssertEqual(MapDotSize.diameter(45, metersPerPoint: mpp), 18, accuracy: 1e-9, "at \(mpp) m a point")
        }
        XCTAssertEqual(MapDotSize.fixedDiameter(45), 18, accuracy: 1e-9)
        XCTAssertGreaterThan(40 / 1.0 - MapDotSize.diameter(45, metersPerPoint: 1.0), 15)
        // Where the dots become fixed: the same size either side, so they don't jump
        XCTAssertEqual(MapDotSize.diameter(45, metersPerPoint: 5.001), MapDotSize.diameter(45, metersPerPoint: 4.999), accuracy: 0.01)
        // The map's scale not known: not fixed, and the labels keep clear of a dot of the fixed size
        XCTAssertFalse(MapDotSize.isFixed(metersPerPoint: 0))
        XCTAssertEqual(MapDotSize.diameter(45, metersPerPoint: 0), 18, accuracy: 1e-9)
    }

    func testLabelsOnlyWhenTheRangeIsBigEnoughOnScreen() {
        XCTAssertFalse(MapLabelLayout.showsLabels(rangeRadius: 69.9))
        XCTAssertTrue(MapLabelLayout.showsLabels(rangeRadius: MapLabelLayout.minRangeRadius))
        XCTAssertTrue(MapLabelLayout.showsLabels(rangeRadius: 200))
        // The bus map labels the nearest five stops only
        XCTAssertEqual(MapLabelLayout.busLabelLimit, 5)
    }

    /// The map's lists of dots stay as they are while nothing changes, and follow every change
    func testDotListsAreMadeAgainOnlyWhenSomethingChanges() {
        func station(_ id: String) -> SubwayMap.Station { SubwayMap.Station(id: id, name: "Station " + id, lat: 40, lon: -74) }
        let base = (1...300).map { station("S\($0)") }
        let gray = [station("G1"), station("G2")]
        var lists = StationDotLists()
        lists.update(base: base, extra: gray, inRange: ["S1", "S2"], fixed: false)
        XCTAssertEqual(lists.made, 1)
        XCTAssertEqual(lists.all.map(\.id), base.map(\.id) + ["G1", "G2"])
        XCTAssertEqual(lists.circles, lists.all, "Zoomed out: every dot is sized in meters")
        XCTAssertTrue(lists.fixedDots.isEmpty)
        XCTAssertEqual(lists.byID["G2"], gray[1])
        XCTAssertNil(lists.baseByID["G2"], "Only the map's own stations")
        XCTAssertEqual(lists.baseByID["S300"], base[299])
        // The same again, the added ones in a new array as the map's view makes them: nothing is made
        lists.update(base: base, extra: [station("G1"), station("G2")], inRange: ["S1", "S2"], fixed: false)
        // Other stations in range don't matter while no dot is drawn at a fixed size
        lists.update(base: base, extra: gray, inRange: ["S7"], fixed: false)
        XCTAssertEqual(lists.made, 1)
        // Zoomed in close: the ones in range leave the first list for the second
        lists.update(base: base, extra: gray, inRange: ["S7", "G1"], fixed: true)
        XCTAssertEqual(lists.made, 2)
        XCTAssertEqual(lists.fixedDots.map(\.id), ["S7", "G1"])
        XCTAssertEqual(lists.circles.count, 300)
        XCTAssertFalse(lists.circles.contains { $0.id == "S7" || $0.id == "G1" })
        lists.update(base: base, extra: gray, inRange: ["S7", "G1"], fixed: true)
        XCTAssertEqual(lists.made, 2)
        lists.update(base: base, extra: gray, inRange: ["S8"], fixed: true)
        XCTAssertEqual(lists.fixedDots.map(\.id), ["S8"])
        XCTAssertEqual(lists.made, 3)
        // Zoomed out again: one list with every dot
        lists.update(base: base, extra: gray, inRange: ["S8"], fixed: false)
        XCTAssertEqual(lists.circles, lists.all)
        XCTAssertTrue(lists.fixedDots.isEmpty)
        // Other stations (the bus map's stops, with none of its own): everything is made again
        lists.update(base: [], extra: [station("B1")], inRange: [], fixed: false)
        XCTAssertEqual(lists.all.map(\.id), ["B1"])
        XCTAssertTrue(lists.baseByID.isEmpty)
        XCTAssertEqual(lists.made, 5)
        // A map with no dots is made once too
        var empty = StationDotLists()
        empty.update(base: [], extra: [], inRange: [], fixed: false)
        empty.update(base: [], extra: [], inRange: [], fixed: false)
        XCTAssertEqual(empty.made, 1)
        XCTAssertTrue(empty.all.isEmpty)
    }
}

/// The day a mode's timetables are up to date as of (see DownloadDates)
final class DownloadDatesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// The earliest operator's: the day only moves on once every operator got through
    func testUpToDateIsTheEarliestOperator() {
        let dates = ["amk": t0, "lirr": t0.addingTimeInterval(86_400), "mnr": t0.addingTimeInterval(2 * 86_400)]
        XCTAssertEqual(DownloadDates.upToDate(dates, of: ["amk", "lirr", "mnr"]), t0)
        XCTAssertEqual(DownloadDates.upToDate(dates, of: ["lirr", "mnr"]), t0.addingTimeInterval(86_400), "An operator turned off doesn't count")
        XCTAssertNil(DownloadDates.upToDate(dates, of: ["amk", "ctr"]), "An operator that never downloaded: no day to say")
        XCTAssertNil(DownloadDates.upToDate(dates, of: []))
    }

    /// Updating from a version that kept one date per store: every operator starts from it; never checked, none
    func testStartsFromTheStoresLastCheck() {
        XCTAssertEqual(DownloadDates.starting(lastChecked: t0, operators: ["amk", "ctr"]), ["amk": t0, "ctr": t0])
        XCTAssertEqual(DownloadDates.starting(lastChecked: nil, operators: ["amk"]), [:])
    }

    /// "next check" is the 1st of next month, even when the day shown is older (an operator keeps failing)
    func testNextCheckIsNeverInThePast() {
        let mac = SubwayMapSchedule.calendar
        let nov20 = mac.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10))!
        XCTAssertEqual(mac.dateComponents([.year, .month, .day], from: DownloadDates.nextCheck(now: nov20)),
                       DateComponents(year: 2026, month: 12, day: 1))
    }
}

/// Where places are on a map view, worked out without the map (MapProjection): the labels are laid out with it
final class MapProjectionTests: XCTestCase {
    /// An area from its top left and bottom right corners, shown in a view 800 points wide of the same shape
    private func projection(_ topLeft: Coordinate, _ bottomRight: Coordinate) -> MapProjection? {
        let a = MapProjection.mapPoint(topLeft), b = MapProjection.mapPoint(bottomRight)
        let width = b.x - a.x, height = b.y - a.y
        return MapProjection(x: a.x, y: a.y, width: width, height: height, viewWidth: 800, viewHeight: 800 * height / width)
    }

    func testWorldPoints() {
        // MapKit's numbers: the world is 2^28 map points across, 0.149291 meters each at the equator
        XCTAssertEqual(MapProjection.worldSize, 268_435_456)
        XCTAssertEqual(MapProjection.metersPerMapPointAtEquator, 0.14929107086948487, accuracy: 1e-12)
        let middle = MapProjection.mapPoint(Coordinate(latitude: 0, longitude: 0))
        XCTAssertEqual(middle.x, MapProjection.worldSize / 2, accuracy: 1e-6)
        XCTAssertEqual(middle.y, MapProjection.worldSize / 2, accuracy: 1e-6)
        XCTAssertEqual(MapProjection.mapPoint(Coordinate(latitude: 0, longitude: -180)).x, 0, accuracy: 1e-6)
        // The map's top edge, and no further at the pole
        XCTAssertEqual(MapProjection.mapPoint(Coordinate(latitude: 85.05112878, longitude: 0)).y, 0, accuracy: 1)
        XCTAssertEqual(MapProjection.mapPoint(Coordinate(latitude: 90, longitude: 0)).y, 0, accuracy: 1)
        // North is up: a place further north is higher on the map
        XCTAssertLessThan(MapProjection.mapPoint(Coordinate(latitude: 40.8, longitude: -74)).y,
                          MapProjection.mapPoint(Coordinate(latitude: 40.7, longitude: -74)).y)
        // Back from a height on the map to its latitude
        for latitude in [-60.0, 0, 40.7580, 51.5] {
            let y = MapProjection.mapPoint(Coordinate(latitude: latitude, longitude: 10)).y
            XCTAssertEqual(MapProjection.latitude(atMapY: y), latitude, accuracy: 1e-9)
        }
    }

    func testCornersAndMiddleOfTheView() throws {
        let topLeft = Coordinate(latitude: 40.77, longitude: -74.01), bottomRight = Coordinate(latitude: 40.74, longitude: -73.96)
        let p = try XCTUnwrap(projection(topLeft, bottomRight))
        let a = p.point(topLeft), b = p.point(bottomRight)
        XCTAssertEqual(a.x, 0, accuracy: 1e-6)
        XCTAssertEqual(a.y, 0, accuracy: 1e-6)
        XCTAssertEqual(b.x, 800, accuracy: 1e-6)
        XCTAssertEqual(b.y, p.viewHeight, accuracy: 1e-6)
        // The middle of the area in map points is the middle of the view; points are from the left edge in every language
        let mapMiddle = (x: p.x + p.width / 2, y: p.y + p.height / 2)
        let middle = Coordinate(latitude: MapProjection.latitude(atMapY: mapMiddle.y), longitude: mapMiddle.x / MapProjection.worldSize * 360 - 180)
        let m = p.point(middle)
        XCTAssertEqual(m.x, 400, accuracy: 1e-6)
        XCTAssertEqual(m.y, p.viewHeight / 2, accuracy: 1e-6)
        // A place outside the area is outside the view
        XCTAssertLessThan(p.point(Coordinate(latitude: 40.80, longitude: -74.05)).y, 0)
    }

    /// The scale agrees with the distance the app measures between two points 10 points apart (WalkEstimator), as the maps did
    /// before when they asked MapKit for the two points
    func testMetersPerPointMatchesMeasuredDistance() throws {
        let p = try XCTUnwrap(projection(Coordinate(latitude: 40.77, longitude: -74.01), Coordinate(latitude: 40.74, longitude: -73.96)))
        let y = p.y + p.height / 2
        let latitude = MapProjection.latitude(atMapY: y)
        func longitude(atViewX vx: Double) -> Double { (p.x + vx / p.viewWidth * p.width) / MapProjection.worldSize * 360 - 180 }
        let measured = WalkEstimator.distanceMeters(Coordinate(latitude: latitude, longitude: longitude(atViewX: 400)),
                                                    Coordinate(latitude: latitude, longitude: longitude(atViewX: 410))) / 10
        XCTAssertEqual(p.metersPerPoint / measured, 1, accuracy: 0.01)
        // Zoomed out twice as far: twice the meters per point
        let wide = try XCTUnwrap(MapProjection(x: p.x - p.width / 2, y: p.y - p.height / 2, width: p.width * 2, height: p.height * 2,
                                               viewWidth: p.viewWidth, viewHeight: p.viewHeight))
        XCTAssertEqual(wide.metersPerPoint / p.metersPerPoint, 2, accuracy: 0.001)
    }

    func testNotUsedWhenTheAreaDoesNotFitTheView() throws {
        let p = try XCTUnwrap(projection(Coordinate(latitude: 40.77, longitude: -74.01), Coordinate(latitude: 40.74, longitude: -73.96)))
        // The view changed size and the map hasn't reported its new area yet
        XCTAssertNil(MapProjection(x: p.x, y: p.y, width: p.width, height: p.height, viewWidth: 800, viewHeight: p.viewHeight * 1.2))
        XCTAssertFalse(MapProjection.sameShape(width: 100, height: 100, viewWidth: 100, viewHeight: 102))
        XCTAssertTrue(MapProjection.sameShape(width: 100, height: 100, viewWidth: 100, viewHeight: 100.5))
        // Turned or tilted
        XCTAssertNil(MapProjection(x: p.x, y: p.y, width: p.width, height: p.height, viewWidth: 800, viewHeight: p.viewHeight, heading: 30))
        XCTAssertNil(MapProjection(x: p.x, y: p.y, width: p.width, height: p.height, viewWidth: 800, viewHeight: p.viewHeight, pitch: 45))
        XCTAssertNotNil(MapProjection(x: p.x, y: p.y, width: p.width, height: p.height, viewWidth: 800, viewHeight: p.viewHeight, heading: 360))
        XCTAssertNotNil(MapProjection(x: p.x, y: p.y, width: p.width, height: p.height, viewWidth: 800, viewHeight: p.viewHeight,
                                      heading: 359.999))
        // No area or no view
        XCTAssertNil(MapProjection(x: p.x, y: p.y, width: 0, height: p.height, viewWidth: 800, viewHeight: p.viewHeight))
        XCTAssertNil(MapProjection(x: p.x, y: p.y, width: p.width, height: p.height, viewWidth: 0, viewHeight: 0))
        XCTAssertNil(MapProjection(x: .nan, y: p.y, width: p.width, height: p.height, viewWidth: 800, viewHeight: p.viewHeight))
    }

    func testAreaAcrossTheDateLine() throws {
        // From 170° E to 170° W: the area goes on past the world's right edge
        let west = MapProjection.mapPoint(Coordinate(latitude: 10, longitude: 170))
        let width = MapProjection.worldSize * 20 / 360
        let p = try XCTUnwrap(MapProjection(x: west.x, y: west.y - width / 2, width: width, height: width, viewWidth: 400, viewHeight: 400))
        XCTAssertEqual(p.point(Coordinate(latitude: 10, longitude: 180)).x, 200, accuracy: 1e-6)
        XCTAssertEqual(p.point(Coordinate(latitude: 10, longitude: -175)).x, 300, accuracy: 1e-6)
        // And back: a click east of the line is a place with a west longitude
        let clicked = p.coordinate(atX: 300, y: 200)
        XCTAssertEqual(clicked.longitude, -175, accuracy: 1e-9)
        XCTAssertEqual(clicked.latitude, 10, accuracy: 1e-9)
        XCTAssertEqual(p.coordinate(atX: 100, y: 200).longitude, 175, accuracy: 1e-9)
    }

    /// A click on the transit map: from a point of the view back to the place there (the map window doesn't ask MapKit)
    func testPlaceAtAPointOfTheView() throws {
        let topLeft = Coordinate(latitude: 40.77, longitude: -74.01), bottomRight = Coordinate(latitude: 40.74, longitude: -73.96)
        let p = try XCTUnwrap(projection(topLeft, bottomRight))
        // The view's corners are the area's
        let corner = p.coordinate(atX: 0, y: 0), far = p.coordinate(atX: 800, y: p.viewHeight)
        XCTAssertEqual(corner.latitude, topLeft.latitude, accuracy: 1e-9)
        XCTAssertEqual(corner.longitude, topLeft.longitude, accuracy: 1e-9)
        XCTAssertEqual(far.latitude, bottomRight.latitude, accuracy: 1e-9)
        XCTAssertEqual(far.longitude, bottomRight.longitude, accuracy: 1e-9)
        // There and back for places in the view and out of it
        for place in [Coordinate(latitude: 40.7557, longitude: -73.9871), Coordinate(latitude: 40.7484, longitude: -73.9857),
                      Coordinate(latitude: 40.80, longitude: -74.05)] {
            let v = p.point(place)
            let back = p.coordinate(atX: v.x, y: v.y)
            XCTAssertEqual(back.latitude, place.latitude, accuracy: 1e-9)
            XCTAssertEqual(back.longitude, place.longitude, accuracy: 1e-9)
        }
        // North is up: a click higher on the view is further north
        XCTAssertGreaterThan(p.coordinate(atX: 400, y: 10).latitude, p.coordinate(atX: 400, y: 20).latitude)
    }

    /// The projection is only for a map that faces north and isn't tilted: the transit map hides its labels otherwise
    func testFacesNorthFlat() {
        XCTAssertTrue(MapProjection.facesNorthFlat(heading: 0, pitch: 0))
        XCTAssertTrue(MapProjection.facesNorthFlat(heading: 360, pitch: 0))
        XCTAssertTrue(MapProjection.facesNorthFlat(heading: 359.999, pitch: 0))
        XCTAssertTrue(MapProjection.facesNorthFlat(heading: -0.001, pitch: 0.001))
        XCTAssertFalse(MapProjection.facesNorthFlat(heading: 30, pitch: 0))
        XCTAssertFalse(MapProjection.facesNorthFlat(heading: 180, pitch: 0))
        XCTAssertFalse(MapProjection.facesNorthFlat(heading: 0, pitch: 45))
        XCTAssertFalse(MapProjection.facesNorthFlat(heading: .nan, pitch: 0))
        XCTAssertFalse(MapProjection.facesNorthFlat(heading: 0, pitch: .infinity))
    }
}

#if canImport(MapKit)
/// On the Mac only: the projection gives MapKit's own map points, and its scale to within 1%
final class MapProjectionMapKitTests: XCTestCase {
    func testSameAsMapKit() throws {
        XCTAssertEqual(MapProjection.worldSize, MKMapSize.world.width)
        XCTAssertEqual(MapProjection.worldSize, MKMapSize.world.height)
        let places = [(40.7557, -73.9871), (40.6437, -74.0736), (40.6084, -75.4902), (0.0, 0.0), (-33.8568, 151.2153), (64.1466, -21.9426)]
        for (latitude, longitude) in places {
            let mapKit = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            let mine = MapProjection.mapPoint(Coordinate(latitude: latitude, longitude: longitude))
            XCTAssertEqual(mine.x, mapKit.x, accuracy: 1)
            XCTAssertEqual(mine.y, mapKit.y, accuracy: 1)
            // The scale at that latitude. MapKit works its own out on the WGS 84 ellipsoid and the projection on a sphere, so they
            // are up to about 0.7% apart (most at the equator): far less than the labels and the dots need
            let p = try XCTUnwrap(MapProjection(x: mapKit.x - 500, y: mapKit.y - 500, width: 1000, height: 1000,
                                                viewWidth: 1000, viewHeight: 1000))
            XCTAssertEqual(p.metersPerPoint / MKMetersPerMapPointAtLatitude(latitude), 1, accuracy: 0.01)
        }
    }
}
#endif

/// The favorite places' stars on the transit map (see FavoriteMarks)
final class FavoriteMarksTests: XCTestCase {
    private func point(_ index: Int, _ x: Double, _ y: Double) -> FavoriteMarks.Point {
        FavoriteMarks.Point(index: index, coordinate: Coordinate(latitude: 40.75 + y / 100_000, longitude: -73.98 + x / 100_000), x: x, y: y)
    }

    /// The places' stars on a view showing this area (map points): each favorite's point on the view
    private func points(_ places: [Coordinate], on projection: MapProjection) -> [FavoriteMarks.Point] {
        places.indices.map { i in
            let p = projection.point(places[i])
            return FavoriteMarks.Point(index: i, coordinate: places[i], x: p.x, y: p.y)
        }
    }

    /// A view `viewWidth` × `viewHeight` points around `center` at this many meters a point
    private func view(_ center: Coordinate, metersPerPoint: Double, viewWidth: Double = 900, viewHeight: Double = 600) throws -> MapProjection {
        let mid = MapProjection.mapPoint(center)
        let metersPerMapPoint = MapProjection.metersPerMapPointAtEquator * cos(center.latitude * .pi / 180)
        let scale = metersPerPoint / metersPerMapPoint
        return try XCTUnwrap(MapProjection(x: mid.x - viewWidth * scale / 2, y: mid.y - viewHeight * scale / 2,
                                           width: viewWidth * scale, height: viewHeight * scale,
                                           viewWidth: viewWidth, viewHeight: viewHeight))
    }

    func testCloseStarsBecomeOne() {
        // 20 points apart: one star in the middle, standing for both
        let one = FavoriteMarks.marks([point(0, 100, 100), point(1, 120, 100)])
        XCTAssertEqual(one.map(\.members), [[0, 1]])
        XCTAssertEqual(one.first?.count, 2)
        XCTAssertEqual(one.first?.x ?? 0, 110, accuracy: 1e-9)
        XCTAssertEqual(one.first?.y ?? 0, 100, accuracy: 1e-9)
        // 30 points apart: two stars, where the favorites are
        let two = FavoriteMarks.marks([point(0, 100, 100), point(1, 130, 100)])
        XCTAssertEqual(two.map(\.members), [[0], [1]])
        XCTAssertEqual(two.map(\.x), [100, 130])
        XCTAssertEqual(two.map(\.coordinate), [point(0, 100, 100).coordinate, point(1, 130, 100).coordinate])
        // Just under the distance and just at it
        XCTAssertEqual(FavoriteMarks.marks([point(0, 0, 0), point(1, 25.9, 0)]).count, 1)
        XCTAssertEqual(FavoriteMarks.marks([point(0, 0, 0), point(1, 0, 26)]).count, 2)
        XCTAssertEqual(FavoriteMarks.mergeDistance, 26)
        // None, and one
        XCTAssertEqual(FavoriteMarks.marks([]), [])
        XCTAssertEqual(FavoriteMarks.marks([point(3, 5, 5)]).map(\.members), [[3]])
    }

    /// The two closest together are made one first: B and C (15 apart) rather than A and B (20 apart). Their star is then 27.5
    /// from A, so A keeps its own
    func testClosestTwoFirst() {
        let marks = FavoriteMarks.marks([point(0, 0, 0), point(1, 20, 0), point(2, 35, 0)])
        XCTAssertEqual(marks.map(\.members), [[0], [1, 2]])
        XCTAssertEqual(marks.last?.x ?? 0, 27.5, accuracy: 1e-9)
    }

    /// A star made of two can then take in a third close to its middle, until no two are closer than the distance
    func testStarsKeepJoiningUntilNoTwoAreClose() {
        let marks = FavoriteMarks.marks([point(0, 0, 0), point(1, 24, 0), point(2, 12, 22), point(3, 200, 0)])
        XCTAssertEqual(marks.map(\.members), [[0, 1, 2], [3]])
        for (a, b) in zip(marks, marks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), FavoriteMarks.mergeDistance)
        }
    }

    /// In the list's order, whatever order the points come in and wherever they are, so the stars don't swap as the map moves
    func testStarsInTheListsOrder() {
        let marks = FavoriteMarks.marks([point(4, 300, 0), point(2, 0, 0), point(0, 150, 0), point(3, 10, 0), point(1, 310, 0)])
        XCTAssertEqual(marks.map(\.members), [[0], [1, 4], [2, 3]])
        // The same again: the same stars
        XCTAssertEqual(FavoriteMarks.marks([point(4, 300, 0), point(2, 0, 0), point(0, 150, 0), point(3, 10, 0), point(1, 310, 0)]), marks)
    }

    /// A star standing for several is drawn in their middle on the map too: on the line between two, for an Annotation there
    func testStarForSeveralInTheirMiddle() throws {
        let a = Coordinate(latitude: 40.7484, longitude: -73.9857), b = Coordinate(latitude: 40.7587, longitude: -73.9787)
        let projection = try view(a, metersPerPoint: 200)
        let marks = FavoriteMarks.marks(points([a, b], on: projection))
        XCTAssertEqual(marks.count, 1)
        let middle = try XCTUnwrap(marks.first)
        XCTAssertEqual(middle.coordinate.latitude, (a.latitude + b.latitude) / 2, accuracy: 1e-4)
        XCTAssertEqual(middle.coordinate.longitude, (a.longitude + b.longitude) / 2, accuracy: 1e-9)
        // And there on the view
        let p = projection.point(middle.coordinate)
        XCTAssertEqual(p.x, middle.x, accuracy: 0.01)
        XCTAssertEqual(p.y, middle.y, accuracy: 0.01)
    }

    /// 50 favorites around the service area, zoomed out to all of it: a few stars, none closer together than the distance, each
    /// favorite in exactly one of them. Zoomed in on Manhattan, its own come apart
    func testFiftyFavoritesZoomedOutAndIn() throws {
        var places: [Coordinate] = []
        // 29 around Manhattan and Brooklyn, the rest in other areas and one outside them all
        for i in 0..<29 { places.append(Coordinate(latitude: 40.70 + Double(i % 6) * 0.015, longitude: -74.01 + Double(i / 6) * 0.012)) }
        for i in 0..<8 { places.append(Coordinate(latitude: 39.94 + Double(i % 3) * 0.01, longitude: -75.17 + Double(i / 3) * 0.01)) }
        for i in 0..<5 { places.append(Coordinate(latitude: 40.60 + Double(i) * 0.01, longitude: -75.47)) }
        for i in 0..<4 { places.append(Coordinate(latitude: 41.76, longitude: -72.68 + Double(i) * 0.01)) }
        for i in 0..<3 { places.append(Coordinate(latitude: 40.22 + Double(i) * 0.01, longitude: -74.76)) }
        places.append(Coordinate(latitude: 42.65, longitude: -73.75))
        XCTAssertEqual(places.count, 50)
        // The whole service area on an 860-point view: about 600 m a point
        let out = try view(Coordinate(latitude: 40.9, longitude: -74.2), metersPerPoint: 600, viewWidth: 860, viewHeight: 560)
        let zoomedOut = FavoriteMarks.marks(points(places, on: out))
        XCTAssertLessThanOrEqual(zoomedOut.count, 10)
        XCTAssertEqual(zoomedOut.flatMap(\.members).sorted(), Array(0..<50))
        for (i, a) in zoomedOut.enumerated() {
            for b in zoomedOut.dropFirst(i + 1) {
                XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), FavoriteMarks.mergeDistance)
            }
        }
        // Each favorite's star is near it: within the merging's reach of where the favorite itself is
        let onView = points(places, on: out)
        for mark in zoomedOut {
            for i in mark.members { XCTAssertLessThan(hypot(onView[i].x - mark.x, onView[i].y - mark.y), 60, "\(i)") }
        }
        // Zoomed in on Manhattan (about 5 m a point): the 29 there are all their own stars
        let manhattan = try view(Coordinate(latitude: 40.74, longitude: -73.98), metersPerPoint: 5, viewWidth: 2000, viewHeight: 2000)
        let zoomedIn = FavoriteMarks.marks(points(Array(places.prefix(29)), on: manhattan))
        XCTAssertEqual(zoomedIn.count, 29)
    }

    /// Clicking a star for several zooms in to them, in the view's shape, so they come apart; two names for one spot never come
    /// apart, so they're listed
    func testClickingZoomsInOrLists() throws {
        let a = Coordinate(latitude: 40.7484, longitude: -73.9857), b = Coordinate(latitude: 40.7505, longitude: -73.9934)
        guard case let .area(x, y, width, height) = FavoriteMarks.zoom([a, b], viewWidth: 900, viewHeight: 600) else {
            return XCTFail("zooms in")
        }
        XCTAssertEqual(width / height, 1.5, accuracy: 1e-9)
        let there = try XCTUnwrap(MapProjection(x: x, y: y, width: width, height: height, viewWidth: 900, viewHeight: 600))
        let marks = FavoriteMarks.marks(points([a, b], on: there))
        XCTAssertEqual(marks.count, 2)
        // Both inside the view, with room around them: here they're furthest apart across, so a sixth of the view either side
        for m in marks {
            XCTAssertGreaterThanOrEqual(m.x, 150 - 0.01)
            XCTAssertLessThanOrEqual(m.x, 750 + 0.01)
            XCTAssertTrue(m.y > 150 && m.y < 450, "\(m.y)")
        }
        // Two favorites 3 m apart (two names for one spot): listed
        let c = Coordinate(latitude: 40.74842, longitude: -73.98572)
        XCTAssertEqual(FavoriteMarks.zoom([a, c], viewWidth: 900, viewHeight: 600), .list)
        // 40 m apart: zoomed in as close as it goes (300 m across) they're 120 points apart, so it zooms in to them
        let d = Coordinate(latitude: 40.74876, longitude: -73.9857)
        guard case let .area(_, _, closeWidth, _) = FavoriteMarks.zoom([a, d], viewWidth: 900, viewHeight: 600) else {
            return XCTFail("zooms in")
        }
        let metersAcross = closeWidth * MapProjection.metersPerMapPointAtEquator * cos(a.latitude * .pi / 180)
        XCTAssertEqual(metersAcross, FavoriteMarks.closestZoomMeters, accuracy: 1)
        // Three: two at one spot and one further off. It zooms in: the third comes apart, the two stay one, and clicking that lists them
        XCTAssertNotEqual(FavoriteMarks.zoom([a, c, b], viewWidth: 900, viewHeight: 600), .list)
        // Not a view, or only one place: nothing to zoom to
        XCTAssertEqual(FavoriteMarks.zoom([a, b], viewWidth: 0, viewHeight: 600), .list)
        XCTAssertEqual(FavoriteMarks.zoom([a], viewWidth: 900, viewHeight: 600), .list)
    }

    /// A favorite saved from a station's card (the station's name, within 30 m) is that station's: a small star on its dot
    func testFavoriteThatIsAStation() {
        let stations = [
            SubwayMap.Station(id: "A", name: "34 St-Herald Sq", lat: 40.749719, lon: -73.987823),
            SubwayMap.Station(id: "B", name: "34 St-Herald Sq", lat: 40.749567, lon: -73.98795),
            SubwayMap.Station(id: "C", name: "Grand Central-42 St", lat: 40.751776, lon: -73.976848),
        ]
        let favorites = [
            // Saved from dot B's card: B's, though A is also within 30 m
            UserPlace(name: "34 St-Herald Sq", coordinate: Coordinate(latitude: 40.749567, longitude: -73.98795)),
            // Another name at the same spot: not the station's
            UserPlace(name: "Macy's", coordinate: Coordinate(latitude: 40.75077, longitude: -73.98922)),
            UserPlace(name: "Herald Square", coordinate: Coordinate(latitude: 40.749719, longitude: -73.987823)),
            // The name, but 200 m away
            UserPlace(name: "Grand Central-42 St", coordinate: Coordinate(latitude: 40.7536, longitude: -73.9768)),
            // The same name and spot as the first again (it can't be saved twice, but a dot is one favorite's at most): dot A
            UserPlace(name: "34 St-Herald Sq", coordinate: Coordinate(latitude: 40.74958, longitude: -73.98794)),
        ]
        XCTAssertEqual(FavoriteMarks.stations(of: favorites, on: stations), [0: "B", 4: "A"])
        XCTAssertEqual(FavoriteMarks.stations(of: favorites, on: []), [:])
    }

    /// The starting point gets no star of its own when it's a favorite (its pin is there); everything else does
    func testStartingPointGetsNoStar() {
        let favorites = [
            UserPlace(name: "Empire State Building", coordinate: Coordinate(latitude: 40.7484, longitude: -73.9857)),
            UserPlace(name: "Bryant Park", coordinate: Coordinate(latitude: 40.7536, longitude: -73.9832)),
            UserPlace(name: "Rockefeller Center", coordinate: Coordinate(latitude: 40.7587, longitude: -73.9787)),
        ]
        let bryant = UserPlace(name: "Bryant Park", coordinate: Coordinate(latitude: 40.75365, longitude: -73.98325))
        XCTAssertEqual(FavoriteMarks.drawn(favorites, origin: bryant), [0, 2])
        // Another name at that spot is another place
        let other = UserPlace(name: "New York Public Library", coordinate: Coordinate(latitude: 40.7536, longitude: -73.9832))
        XCTAssertEqual(FavoriteMarks.drawn(favorites, origin: other), [0, 1, 2])
        XCTAssertEqual(FavoriteMarks.drawn(favorites, origin: nil), [0, 1, 2])
        XCTAssertEqual(FavoriteMarks.drawn([], origin: bryant), [])
    }

    /// A star the starting point's pin covers goes beside the pin, 2 points away: to the right, or the left when the right is off
    /// the view or taken by another star (the left first in right-to-left layouts). Stars clear of the pin stay where they are
    func testStarsKeepClearOfTheStartingPoint() {
        typealias Box = FavoriteMarks.Box
        // The pin standing on (150, 118): 32 wide, from 42 above its point to 4 below
        let pin = Box(x: 134, y: 76, width: 32, height: 46)
        // A star for several, 37 wide, under the pin's head, and one far away
        let covered = Box(x: 133, y: 85, width: 37, height: 22)
        let far = Box(x: 300, y: 85, width: 22, height: 22)
        // To the right: its left edge 2 points past the pin's right edge (166 + 2)
        XCTAssertEqual(FavoriteMarks.offsets([covered, far], clearOf: pin, viewWidth: 600), [35, 0])
        // Off the view on the right: to the left, its right edge 2 points before the pin's left edge (134 - 2)
        XCTAssertEqual(FavoriteMarks.offsets([covered], clearOf: pin, viewWidth: 190), [-38])
        // Another star where it would go on the right: to the left
        let beside = Box(x: 180, y: 90, width: 22, height: 22)
        XCTAssertEqual(FavoriteMarks.offsets([covered, beside], clearOf: pin, viewWidth: 600), [-38, 0])
        // Right-to-left: the left first, the right when the left is off the view
        XCTAssertEqual(FavoriteMarks.offsets([covered], clearOf: pin, viewWidth: 600, rightToLeft: true), [-38])
        let nearLeftEdge = Box(x: 4, y: 76, width: 32, height: 46)
        let star = Box(x: 10, y: 85, width: 22, height: 22)
        XCTAssertEqual(FavoriteMarks.offsets([star], clearOf: nearLeftEdge, viewWidth: 600, rightToLeft: true), [28])
        // Neither side free: the first side tried
        let left = Box(x: 100, y: 90, width: 22, height: 22)
        XCTAssertEqual(FavoriteMarks.offsets([covered, left], clearOf: pin, viewWidth: 190), [35, 0])
        // Only touching the pin's edge isn't covered
        XCTAssertEqual(FavoriteMarks.offsets([Box(x: 166, y: 85, width: 22, height: 22)], clearOf: pin, viewWidth: 600), [0])
        // The current location's dot (24 x 24 around its point) is kept clear of the same way
        let dot = Box(x: 138, y: 106, width: 24, height: 24)
        XCTAssertEqual(FavoriteMarks.offsets([Box(x: 140, y: 100, width: 22, height: 22)], clearOf: dot, viewWidth: 600), [24])
        XCTAssertEqual(FavoriteMarks.offsets([], clearOf: pin, viewWidth: 600), [])
    }
}

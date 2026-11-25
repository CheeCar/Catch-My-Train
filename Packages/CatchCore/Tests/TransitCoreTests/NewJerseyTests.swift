import XCTest
@testable import TransitCore

/// New Jersey and Philadelphia: NJ Transit trains and light rail (same feed), Amtrak on both sides, SEPTA Regional Rail, New Jersey ferries.
/// Samples use the same format as the real data (checked on a Mac); for real data see testRealNewJerseyDataIfAvailable.
final class NewJerseyTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    /// 2026-10-14 (Wednesday), noon in New York
    private let now = Date(timeIntervalSince1970: 1_791_993_600)

    /// NJ Transit: trains (route_type 2) and light rail (0) together, one line has two route_ids, stop names are all caps, no calendar.txt.
    private var njtFiles: [String: Data] {
        [
            "agency.txt": d("""
            agency_id,agency_name,agency_url,agency_timezone,agency_lang,agency_phone
            NJT,NJ TRANSIT RAIL,http://www.njtransit.com/,America/New_York,en,
            """),
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_url,route_color
            2,NJT,BNTN,Montclair-Boonton Line,2,,E66859
            3,NJT,BNTNM,Montclair-Boonton Line,2,,E66859
            4,NJT,HBLR,Hudson-Bergen Light Rail,0,,008080
            10,NJT,NEC,Northeast Corridor,2,,DD3439
            13,NJT,NLR,Newark Light Rail,0,,009AD1
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,zone_id
            1,95001,30TH ST. PHL.,,39.956565,-75.182327,5961
            105,95105,NEW YORK PENN STATION,,40.750046,-73.992358,1
            107,95107,NEWARK PENN STATION,,40.734221,-74.164554,2
            148,95148,TRENTON TRANSIT CENTER,,40.218515,-74.753926,3
            38174,95167,SECAUCUS LOWER LEVEL,,40.761188,-74.075821,4
            106,95106,NEWARK BROAD ST,,40.747621,-74.171943,5
            36994,30833,EXCHANGE PLACE LIGHT RAIL STATION,,40.716009,-74.034092,6
            39348,30829,HOBOKEN TERMINAL LIGHT RAIL STATION,,40.734059,-74.029192,7
            26326,30771,PENN STATION LIGHT RAIL DEPARTURE,,40.734810,-74.163603,8
            6966,30765,PARK AVENUE NEWARK LIGHT RAIL STATION,,40.758560,-74.184941,9
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
            10,1,1,NEW YORK PENN STATION,1,4660,1
            10,1,2,TRENTON,0,4661,2
            2,1,3,NEWARK BROAD ST,0,4662,3
            3,1,4,NEWARK BROAD ST,0,4663,3
            4,1,5,HOBOKEN,1,4664,4
            13,1,6,PARK AVENUE,0,4665,5
            10,9,7,NEW YORK PENN STATION,1,4666,1
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type,shape_dist_traveled
            1,12:10:00,12:10:00,148,1,0,0,0
            1,12:55:00,12:55:00,107,2,0,0,40
            1,13:05:00,13:05:00,38174,3,0,0,45
            1,13:15:00,13:15:00,105,4,0,0,50
            2,13:30:00,13:30:00,105,1,0,0,0
            2,13:40:00,13:40:00,38174,2,0,0,5
            2,13:50:00,13:50:00,107,3,0,0,10
            2,14:35:00,14:35:00,148,4,0,0,50
            3,12:30:00,12:30:00,105,1,0,0,0
            3,12:50:00,12:50:00,38174,2,0,0,5
            3,13:05:00,13:05:00,106,3,0,0,10
            4,14:30:00,14:30:00,105,1,0,0,0
            4,14:50:00,14:50:00,38174,2,0,0,5
            4,15:05:00,15:05:00,106,3,0,0,10
            5,12:20:00,12:20:00,36994,1,0,0,0
            5,12:30:00,12:30:00,39348,2,0,0,3
            6,12:20:00,12:20:00,26326,1,0,0,0
            6,12:35:00,12:35:00,6966,2,0,0,4
            7,12:10:00,12:10:00,148,1,0,0,0
            7,13:15:00,13:15:00,105,2,0,0,50
            """),
            "calendar_dates.txt": d("""
            service_id,date,exception_type
            1,20261013,1
            1,20261014,1
            1,20261015,1
            9,20270301,1
            """),
        ]
    }

    /// Amtrak: other operators' routes (intercity buses, MARC), times without zero padding, unreliable direction_id, Newark drop-off only.
    private var amtrakFiles: [String: Data] {
        [
            "agency.txt": d("""
            agency_id,agency_name,agency_url,agency_timezone,agency_lang
            51,Amtrak,https://www.amtrak.com,America/New_York,en
            1238,MARC,https://www.mta.maryland.gov,America/New_York,en
            """),
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_url,route_color,route_text_color
            88,51,,Northeast Regional,2,,CAE4F1,000000
            94,51,,Keystone Service,2,,CAE4F1,000000
            999,1238,,MARC Penn Line,2,,CAE4F1,000000
            777,51,,Amtrak Thruway,3,,CAE4F1,000000
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_url,stop_timezone,stop_lat,stop_lon
            WAS,WAS,Washington Union Station,,,38.89768,-77.006337
            PHL,PHL,Philadelphia,,,39.955615,-75.181041
            NWK,NWK,Newark,,,40.734706,-74.16475
            NYP,NYP,Ny Moynihan Train Hall At Penn Station,,,40.750327,-73.994459
            NRO,NRO,New Rochelle Amtrak Station,,,40.911451,-73.784329
            STM,STM,Stamford Amtrak Station,,,41.04713,-73.54216
            NHV,NHV,New Haven,,,41.297714,-72.92667
            STS,STS,New Haven,,,41.305253,-72.922086
            BOS,BOS,Boston South Station,,,42.352271,-71.055242
            HAR,HAR,Harrisburg,,,40.261516,-76.877703
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_short_name,direction_id,shape_id,trip_headsign
            88,S1,171,171,0,,Boston
            88,S1,172,172,0,,Washington
            94,S1,676,676,1,,New York
            999,S1,500,500,0,,Baltimore
            777,S1,600,600,0,,Albany
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type,timepoint
            171,7:00:00,7:00:00,WAS,1,0,0,1
            171,8:30:00,8:32:00,PHL,2,0,0,1
            171,9:40:00,9:41:00,NWK,3,0,0,1
            171,10:00:00,10:10:00,NYP,4,0,0,1
            171,10:40:00,10:41:00,NRO,5,0,0,1
            171,11:05:00,11:06:00,STM,6,0,0,1
            171,11:50:00,11:52:00,NHV,7,0,0,1
            171,14:30:00,14:30:00,BOS,8,0,0,1
            172,8:00:00,8:00:00,BOS,1,0,0,1
            172,10:30:00,10:32:00,NHV,2,0,0,1
            172,11:20:00,11:21:00,STM,3,0,0,1
            172,12:10:00,12:25:00,NYP,4,0,0,1
            172,12:40:00,12:41:00,NWK,5,1,0,1
            172,13:30:00,13:32:00,PHL,6,0,0,1
            172,15:00:00,15:00:00,WAS,7,0,0,1
            676,20:20:00,20:20:00,HAR,1,0,0,1
            676,22:10:00,22:19:00,PHL,2,0,0,1
            676,23:22:00,23:23:00,NWK,3,0,0,1
            676,23:42:00,23:42:00,NYP,4,0,0,1
            500,9:00:00,9:00:00,WAS,1,0,0,1
            500,10:00:00,10:00:00,PHL,2,0,0,1
            600,9:00:00,9:00:00,NYP,1,0,0,1
            600,11:00:00,11:00:00,NHV,2,0,0,1
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            S1,1,1,1,1,1,1,1,20261011,20271011
            """),
        ]
    }

    /// SEPTA Regional Rail: like the real data, no stop_code or location_type, the line's code in front of the train number
    /// (trip_short_name "TRE9714"), one color for every line, and its own names for the stations it shares with Amtrak and NJ Transit
    /// ("Gray 30th St Station"; North Philadelphia has two platforms about 150 m apart). Positions as in the real data.
    private var septaFiles: [String: Data] {
        [
            "agency.txt": d("""
            agency_id,agency_name,agency_url,agency_timezone,agency_lang,agency_phone,agency_fare_url,cemv_support
            SEPTA,SEPTA,http://www.septa.org/,America/New_York,en,,,1
            """),
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_url,route_color,route_text_color
            TRE,SEPTA,TRE,Trenton Line,2,,4F758B,FFFFFF
            CHW,SEPTA,CHW,Chestnut Hill West Line,2,,4F758B,FFFFFF
            WIL,SEPTA,WIL,Wilmington/Newark Line,2,,4F758B,FFFFFF
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_desc,stop_lat,stop_lon,zone_id,stop_url,wheelchair_boarding
            90004,Gray 30th St Station,,39.95667,-75.18166,C,,1
            90005,Suburban Station,,39.95389,-75.16778,C,,1
            90711,North Philadelphia Amtrak,,39.99678,-75.15511,1S,,2
            90810,North Philadelphia Septa,,39.99778,-75.15639,1S,,2
            90706,Cornwells Heights,,40.0709,-74.95432,3S,,1
            90701,Trenton,,40.21851,-74.75393,NJ,,1
            90203,Wilmington,,39.73726,-75.55109,4S,,1
            90201,Newark DE,,39.66969,-75.75351,4S,,1
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id,bikes_allowed,wheelchair_accessible,trip_short_name
            TRE,WK,TRE9714_20261005_WK,Trenton,1,9714,,2,1,TRE9714
            TRE,WK,TRE9729_20261005_WK,30th Street Station,0,9729,,2,1,TRE9729
            CHW,WK,CHW9810_20261005_WK,Chestnut Hill West,1,9810,,2,1,CHW9810
            WIL,WK,WIL9230_20261005_WK,Newark,1,9230,,2,1,WIL9230
            WIL,LATER,WIL9232_20270104_LATER,Newark,1,9232,,2,1,WIL9232
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,stop_headsign,pickup_type,drop_off_type,shape_dist_traveled,timepoint
            TRE9714_20261005_WK,12:00:00,12:00:00,90004,1,Trenton,,,,1
            TRE9714_20261005_WK,12:06:00,12:06:00,90005,2,Trenton,,,,1
            TRE9714_20261005_WK,12:16:00,12:16:00,90711,3,Trenton,,,,1
            TRE9714_20261005_WK,12:35:00,12:35:00,90706,4,Trenton,,,,1
            TRE9714_20261005_WK,13:00:00,13:00:00,90701,5,Trenton,,,,1
            TRE9729_20261005_WK,12:10:00,12:10:00,90701,1,30th Street Station,,,,1
            TRE9729_20261005_WK,12:36:00,12:36:00,90706,2,30th Street Station,,,,1
            TRE9729_20261005_WK,12:55:00,12:55:00,90711,3,30th Street Station,,,,1
            TRE9729_20261005_WK,13:05:00,13:05:00,90005,4,30th Street Station,,,,1
            TRE9729_20261005_WK,13:11:00,13:11:00,90004,5,30th Street Station,,,,1
            CHW9810_20261005_WK,12:20:00,12:20:00,90005,1,Chestnut Hill West,,,,1
            CHW9810_20261005_WK,12:25:00,12:25:00,90004,2,Chestnut Hill West,,,,1
            CHW9810_20261005_WK,12:40:00,12:40:00,90810,3,Chestnut Hill West,,,,1
            WIL9230_20261005_WK,12:30:00,12:30:00,90004,16,Newark,,,,1
            WIL9230_20261005_WK,13:00:00,13:00:00,90203,17,Newark,,,,1
            WIL9230_20261005_WK,13:25:00,13:25:00,90201,18,Newark,,,,1
            WIL9232_20270104_LATER,12:30:00,12:30:00,90004,1,Newark,,,,1
            WIL9232_20270104_LATER,13:00:00,13:00:00,90203,2,Newark,,,,1
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WK,1,1,1,1,1,0,0,20261005,20270220
            LATER,1,1,1,1,1,0,0,20270104,20270220
            """),
            "calendar_dates.txt": d("""
            service_id,date,exception_type
            WK,20261126,2
            """),
            "feed_info.txt": d("""
            feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date,feed_version
            SEPTA,https://septa.org/,en,20261005,20261121,v202610050
            """),
        ]
    }

    // MARK: Systems and regions

    /// New York and New Jersey aren't split: four transit modes, each covering the whole metro area; PATH and light rail count as subway
    func testModesAndSystems() {
        XCTAssertEqual(TransitSystem.modes, [.subway, .bus, .train, .ferry])
        XCTAssertEqual(TransitSystem.path.mode, .subway)
        XCTAssertEqual(TransitSystem.lightRail.mode, .subway)
        XCTAssertTrue(TransitSystem.subway.hasTimetablePart)
        XCTAssertFalse(TransitSystem.subway.usesTimetableFeed)
        XCTAssertEqual(TransitSystem.subway.timetableSystems, [.path, .lightRail])
        XCTAssertEqual(TransitSystem.bus.timetableSystems, [.njBus])
        // Previously stored New Jersey systems are replaced by the merged ones
        XCTAssertEqual(TransitSystem.njTrain.mode, .train)
        XCTAssertEqual(TransitSystem.njFerry.mode, .ferry)
        XCTAssertEqual(TransitSystem.njBus.mode, .bus)
        XCTAssertEqual(TransitSystem.njTrain.nameKey, "Train")
        XCTAssertEqual(TransitSystem.lightRail.family, .rail)
        XCTAssertEqual(TransitSystem.njFerry.dataSystem, .ferry)
        XCTAssertEqual(TransitSystem.njTrain.dataSystem, .train)
        XCTAssertTrue(TransitSystem.train.usesTimetableFeed && TransitSystem.lightRail.usesTimetableFeed)
        // Bus: MTA uses live data, NJ Transit and others use timetables
        XCTAssertFalse(TransitSystem.bus.usesTimetableFeed)
        XCTAssertTrue(TransitSystem.bus.hasTimetablePart)
        XCTAssertEqual(TransitSystem.bus.timetableSystem, .njBus)
        // Train: LIRR, Metro-North, NJ Transit, MBTA Commuter Rail, Amtrak, SEPTA, the Hartford Line and MARC together
        XCTAssertEqual(FerryFeed.Source.cases(for: .train),
                       [.lirr, .metroNorth, .njTransitRail, .mbtaRail, .amtrakNY, .septaRail, .hartfordLine, .marc])
        XCTAssertEqual(FerryFeed.Source.cases(for: .njTrain), FerryFeed.Source.cases(for: .train))
        // Light rail keeps SEPTA Metro, PATCO and the MBTA's subway too (all shown under Subway)
        XCTAssertEqual(FerryFeed.Source.cases(for: .lightRail), [.njTransitLightRail, .septaMetro, .patco, .mbtaSubway])
        // The ones whose live data the subway's refresh downloads without an account (PATH has its own; NJ Transit's needs one)
        XCTAssertEqual(FerryFeed.Source.freeLiveLightRail, [.septaMetro, .mbtaSubway])
        XCTAssertEqual(FerryFeed.Source.cases(for: .njFerry), FerryFeed.Source.cases(for: .ferry))
        // All timetable-only
        for s in [FerryFeed.Source.njTransitRail, .njTransitLightRail, .amtrakNY] { XCTAssertFalse(s.hasRealtime) }
    }

    /// The boxes' outline (the place picker's map frames it) is the boxes: for each grid point, being inside the outline (even-odd
    /// rule) equals being in a box. The service area is the part of them in the areas' counties (ServiceArea.contains)
    func testServiceAreaOutlineMatchesBoxes() {
        let loops = ServiceArea.outline
        XCTAssertFalse(loops.isEmpty)
        for loop in loops { XCTAssertGreaterThanOrEqual(loop.count, 4) }
        func inOutline(_ p: Coordinate) -> Bool {
            var inside = false
            for loop in loops {
                for i in loop.indices {
                    let a = loop[i], b = loop[(i + 1) % loop.count]
                    if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                        let lon = a.longitude + (p.latitude - a.latitude) / (b.latitude - a.latitude) * (b.longitude - a.longitude)
                        if p.longitude < lon { inside.toggle() }
                    }
                }
            }
            return inside
        }
        var checked = 0
        // The step isn't an integer multiple of the boundary values, so grid points never land exactly on an edge
        var lat = 38.6013
        while lat < 42.5 {
            var lon = -75.9017
            while lon < -71.5 {
                let p = Coordinate(latitude: lat, longitude: lon)
                XCTAssertEqual(inOutline(p), ServiceArea.inBoxes(p), "\(lat), \(lon)")
                checked += 1
                lon += 0.0331
            }
            lat += 0.0237
        }
        XCTAssertGreaterThan(checked, 10_000)
        // All outline corners are right angles (only horizontal and vertical lines)
        for loop in loops {
            for i in loop.indices {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                XCTAssertTrue(a.latitude == b.latitude || a.longitude == b.longitude)
            }
        }
    }

    func testServiceArea() {
        let inside: [(String, Double, Double)] = [
            ("Times Sq", 40.7557, -73.9871), ("Hoboken", 40.7359, -74.0291), ("Hempstead", 40.7134, -73.6252),
            ("Montauk", 41.0471, -71.9540), ("Poughkeepsie", 41.7066, -73.9379), ("New Haven", 41.2977, -72.9267),
            ("Stamford", 41.0471, -73.5422), ("Milford PA", 41.3226, -74.8024), ("Trenton", 40.2185, -74.7539),
            ("Philadelphia 30th St", 39.9556, -75.1820), ("Newburgh", 41.5034, -74.0104), ("Wassaic", 41.8148, -73.5622),
            ("Kingston", 41.9270, -73.9974), ("Monticello", 41.6556, -74.6893),
            // Philadelphia's western suburbs and northern Delaware; southeastern Connecticut to the Rhode Island line
            ("Paoli", 40.0429, -75.4836), ("Pottstown", 40.2454, -75.6496), ("Coatesville", 39.9857, -75.8202),
            ("Newark DE", 39.6697, -75.7535), ("Middletown DE", 39.4496, -75.7163), ("New London", 41.3543, -72.0932),
            ("Mystic", 41.3508, -71.9634), ("Foxwoods", 41.4735, -71.9614),
            // Berks County (BARTA), western Chester County (TMACC) and Cecil County, MD (Cecil Transit)
            ("Reading", 40.3356, -75.9269), ("Boyertown", 40.3337, -75.6374), ("Kutztown", 40.5173, -75.7774),
            ("Parkesburg", 39.9590, -75.9194), ("Oxford PA", 39.7851, -75.9788), ("Elkton", 39.6068, -75.8333),
            ("Perryville", 39.5604, -76.0716),
            // The Lehigh Valley
            ("Allentown", 40.6023, -75.4714), ("Bethlehem", 40.6259, -75.3705), ("Easton", 40.6884, -75.2207),
            ("Jim Thorpe", 40.8676, -75.7402), ("Palmerton", 40.8015, -75.6102), ("Stroudsburg", 40.9868, -75.1946),
            ("Mount Pocono", 41.1220, -75.3646), ("Phillipsburg", 40.6937, -75.1902), ("Hackettstown", 40.8529, -74.8291),
            // Between the Lehigh Valley, Berks County and the western suburbs (Montgomery County)
            ("Red Hill PA", 40.3726, -75.4807), ("Green Lane PA", 40.3373, -75.4724),
            // Greater Hartford with the northeastern corner and the Northwest Hills; Western Massachusetts
            ("Hartford", 41.7658, -72.6734), ("Berlin CT", 41.636, -72.774), ("Enfield", 41.9762, -72.5918),
            ("Putnam CT", 41.9151, -71.9087), ("Danielson", 41.8023, -71.8859), ("Torrington", 41.8007, -73.1212),
            ("Canaan CT", 42.0273, -73.3293), ("Springfield MA", 42.1015, -72.5898), ("Northampton", 42.3195, -72.6306),
            ("Greenfield MA", 42.5854, -72.6006), ("Pittsfield", 42.4501, -73.2454), ("North Adams", 42.7009, -73.1087),
            ("Great Barrington", 42.1959, -73.3621),
            // Between the two, with no stop nearby (no holes, rule 6)
            ("Salisbury CT", 41.983, -73.421), ("Sheffield MA", 42.110, -73.355), ("Sandisfield MA", 42.110, -73.130),
            // North of Greenfield up to Vermont and New Hampshire, with no stop nearby: left out, a notch between the Berkshires
            // and Greater Boston (rule 6)
            ("Northfield MA", 42.6965, -72.4529), ("Bernardston MA", 42.6709, -72.5490), ("Rowe MA", 42.6948, -72.9254),
        ]
        for (name, lat, lon) in inside {
            XCTAssertTrue(ServiceArea.contains(Coordinate(latitude: lat, longitude: lon)), name)
        }
        let outside: [(String, Double, Double)] = [
            ("Albany", 42.6526, -73.7562), ("Hudson NY", 42.2529, -73.7910), ("Brattleboro VT", 42.8509, -72.5579),
            ("Bennington VT", 42.8781, -73.1968), ("Hinsdale NH", 42.7862, -72.4862),
            ("Portland ME", 43.6591, -70.2568), ("Wells ME (Downeaster)", 43.3219, -70.6115),
            ("Washington", 38.8977, -77.0063), ("Harrisburg", 40.2615, -76.8777), ("Wilkes-Barre", 41.2459, -75.8813),
            ("Pottsville", 40.6856, -76.1955), ("Scranton", 41.4090, -75.6624),
            ("Lancaster", 40.0538, -76.3077), ("Aberdeen MD", 39.5096, -76.1641),
            ("Lebanon PA", 40.3409, -76.4113), ("Bel Air MD", 39.5359, -76.3483), ("Copake NY", 42.103, -73.553),
        ]
        for (name, lat, lon) in outside {
            XCTAssertFalse(ServiceArea.contains(Coordinate(latitude: lat, longitude: lon)), name)
        }
        // The user's location gets an extra 15 km: places at the edge count as inside, far ones still don't
        XCTAssertTrue(ServiceArea.containsWithMargin(Coordinate(latitude: 42.7862, longitude: -72.4862)), "Hinsdale NH")
        XCTAssertNotNil(MetroSubRegion.of(Coordinate(latitude: 42.7862, longitude: -72.4862)))
        for (name, lat, lon) in [("Albany", 42.6526, -73.7562), ("Washington", 38.8977, -77.0063), ("Portland ME", 43.6591, -70.2568)] {
            XCTAssertFalse(ServiceArea.containsWithMargin(Coordinate(latitude: lat, longitude: lon)), name)
        }
        // Where address search looks first: one box around them all, from Cape May to Laconia and from Berks County to Cape Cod
        XCTAssertEqual(ServiceArea.bounds.lat, 38.85...43.80)
        XCTAssertEqual(ServiceArea.bounds.lon, -76.25 ... -69.90)
        for (name, lat, lon) in inside {
            XCTAssertTrue(ServiceArea.bounds.lat.contains(lat) && ServiceArea.bounds.lon.contains(lon), name)
        }
    }

    /// Tripwire: stored data depends on these boxes, because reading the packages cuts Amtrak and Hartford Line stations to them and drops ferry routes
    /// reaching outside them. If this fails after changing the boxes, raise FerryFeed.contentVersion for trains (and for ferries if a ferry route
    /// falls in or out), so stored copies are read again once, then update the boxes here. CTtransit's bus stops are cut to them too: if a box
    /// changes in Connecticut, raise its RegionalBusFeed.readingVersion as well.
    func testChangingTheServiceAreaRebuildsStoredTrainData() {
        let boxes: [[Double]] = [
            [39.85, 41.62, -75.35, -73.40],
            [41.40, 42.10, -74.30, -73.45],
            [41.40, 42.20, -75.20, -73.90],
            [40.50, 41.20, -73.45, -71.80],
            [40.95, 41.62, -73.75, -71.84],
            [38.85, 39.90, -75.65, -73.85],
            [39.35, 40.30, -75.90, -75.35],
            // Berks County's, reaching down to the box below, so no strip of the county is left between the two
            [40.20, 40.60, -76.25, -75.53],
            [39.52, 40.20, -76.15, -75.90],
            // The Lehigh Valley's: no Amtrak or Hartford Line station and no ferry route is in them
            [40.30, 41.17, -76.04, -75.30],
            [41.10, 41.29, -75.69, -75.30],
            // Greater Boston's: Amtrak's stations from Westerly to Boston, on the Downeaster to Dover and on the Lake Shore Limited
            // at Worcester and Framingham are in them. No ferry route the app reads reaches them
            [42.00, 43.10, -72.36, -70.55],
            [41.12, 42.05, -71.87, -71.10],
            [41.48, 42.05, -71.20, -70.60],
            [41.52, 42.10, -70.70, -69.90],
            // Martha's Vineyard with the Elizabeth Islands, and Nantucket, in one box with the water between them and the mainland
            // (Noman's Land and Nantucket's Great Point too): no train station, CTtransit stop or ferry route the app reads is in it
            // (Seastreak's boats to Martha's Vineyard, in New York's data, stay out: see FerryBuilder.staysInItsAreas)
            [41.12, 41.52, -71.10, -69.90],
            // New Hampshire's, split at the state line so they reach York County, Maine, only where COAST runs: the Downeaster's
            // stations from Exeter to Dover are in them, and Wells, Saco and the rest in Maine out
            [43.05, 43.30, -72.25, -70.70],
            [43.30, 43.35, -72.25, -70.90],
            [43.35, 43.55, -72.25, -70.95],
            [43.55, 43.80, -72.25, -71.00],
            // Greater Hartford's two and Western Massachusetts' two: the Hartford Line's and Amtrak's stations from Berlin to
            // Springfield, Amtrak's at Holyoke, Northampton, Greenfield and Pittsfield, and CTtransit's stops around Hartford and
            // New Britain are in them; no ferry route is. The Northwest Hills' (west from -73.38) and the Berkshires' (south from
            // 42.14, west from -73.42) reach the state lines, so no part of their counties is left between them (Salisbury,
            // Sheffield), and the Pioneer Valley's reaches north to Vermont and New Hampshire (Northfield, Bernardston, Rowe)
            [41.55, 42.05, -72.97, -71.80],
            [41.60, 42.06, -73.55, -72.97],
            [42.00, 42.75, -73.00, -72.20],
            [42.00, 42.75, -73.52, -73.00],
        ]
        XCTAssertEqual(ServiceArea.boxes.map { [$0.lat.lowerBound, $0.lat.upperBound, $0.lon.lowerBound, $0.lon.upperBound] }, boxes)
        XCTAssertEqual(FerryFeed.contentVersion(for: .train), 7)
        XCTAssertEqual(FerryFeed.contentVersion(for: .ferry), 1)
        // The only bus company cut to the boxes, with its mark; the others with one have it for how their data is read
        XCTAssertEqual(RegionalBusFeed.builtIn.filter(\.onlyServiceArea).map(\.code), ["CTT"])
        XCTAssertEqual(RegionalBusFeed.builtIn.filter { $0.readingVersion != 0 }.map { "\($0.code) \($0.readingVersion)" },
                       [" 1", "CTT 1", "PVTA 1", "FRTA 2", "NECTD 1", "WRTD 2", "NWCTD 1"])
    }

    func testBusCompaniesReadAnOlderWayAreReadAgain() {
        let feeds = RegionalBusFeed.builtIn
        // A copy stored before marks were kept counts as 0: only the companies whose reading changed are read again. NJ Transit
        // is one of them (its stops' codes), and its code is the empty one
        XCTAssertEqual(RegionalBusFeed.outdated(stored: ["", "NICE", "CTT", "PVTA", "BRTA"], readWith: [:], feeds: feeds), ["", "CTT", "PVTA"])
        // Not one that isn't stored: it's downloaded as a missing one, and read this version's way
        XCTAssertEqual(RegionalBusFeed.outdated(stored: ["NICE", "BRTA"], readWith: [:], feeds: feeds), [])
        // Once it downloaded fine its mark is this version's, and it isn't read again
        let marks = RegionalBusFeed.marking([:], read: ["", "NICE", "CTT"], feeds: feeds)
        XCTAssertEqual(marks, ["": 1, "CTT": 1])
        XCTAssertEqual(RegionalBusFeed.outdated(stored: ["", "NICE", "CTT"], readWith: marks, feeds: feeds), [])
        // NJ Transit's alone: read again once, then not again; the others' marks stay as they were
        XCTAssertEqual(RegionalBusFeed.outdated(stored: ["", "CTT"], readWith: ["CTT": 1], feeds: feeds), [""])
        let njTransitRead = RegionalBusFeed.marking(["CTT": 1], read: [""], feeds: feeds)
        XCTAssertEqual(njTransitRead, ["": 1, "CTT": 1])
        XCTAssertEqual(RegionalBusFeed.outdated(stored: ["", "CTT"], readWith: njTransitRead, feeds: feeds), [])
        // A download without it leaves its mark as it was
        XCTAssertEqual(RegionalBusFeed.marking([:], read: ["NICE", "BRTA"], feeds: feeds), [:])
        XCTAssertEqual(RegionalBusFeed.marking(["CTT": 1], read: ["BRTA"], feeds: feeds), ["CTT": 1])
        XCTAssertEqual(RegionalBusFeed.marking(["CTT": 1], read: ["PVTA"], feeds: feeds), ["CTT": 1, "PVTA": 1])
        // A mark from a later version than this one isn't read again either
        XCTAssertEqual(RegionalBusFeed.outdated(stored: ["CTT"], readWith: ["CTT": 2], feeds: feeds), [])
    }

    func testStationNames() {
        XCTAssertEqual(FerryFeed.Source.amtrakCode("Downeaster"), "DOW")
        XCTAssertEqual(FerryFeed.Source.amtrakCode("Lincoln Service"), "LS")
        XCTAssertEqual(FerryFeed.Source.amtrakNY.routeID("42946", name: "Montreal - New York"), "AMK-MNY")
        XCTAssertEqual(FerryFeed.Source.amtrakNY.routeID("88", name: "Northeast Regional"), "AMK-NER")
        XCTAssertEqual(FerryFeed.Source.amtrakNY.routeID("5", name: ""), "AMK-5")
        XCTAssertEqual(FerryBuilder.njTransitStationName("NEWARK PENN STATION"), "Newark Penn Station")
        XCTAssertEqual(FerryBuilder.njTransitStationName("30TH ST. PHL."), "Philadelphia 30th Street")
        XCTAssertEqual(FerryBuilder.njTransitStationName("EXCHANGE PLACE LIGHT RAIL STATION"), "Exchange Place")
        XCTAssertEqual(FerryBuilder.njTransitStationName("LIBERTY STATE PARK-RIDE LIGHT RAIL STA"), "Liberty State Park-Ride")
        XCTAssertEqual(FerryBuilder.njTransitStationName("PENN STATION LIGHT RAIL ARRIVAL"), "Newark Penn Station")
        XCTAssertEqual(FerryBuilder.njTransitStationName("ROUTE 73/PENNSAUKEN LIGHT RAIL STATION"), "Route 73/Pennsauken")
        XCTAssertEqual(FerryBuilder.njTransitStationName("MSU"), "MSU")
        XCTAssertEqual(FerryBuilder.njTransitStationName("MAIN ST AT ADAMS AVE"), "Main St At Adams Ave")
        XCTAssertEqual(FerryBuilder.amtrakStationName("Stamford Amtrak Station", source: .amtrakNY), "Stamford")
        XCTAssertEqual(FerryBuilder.amtrakStationName("Ny Moynihan Train Hall At Penn Station", source: .amtrakNY), "Penn Station")
        XCTAssertEqual(FerryBuilder.amtrakStationName("Newark", source: .amtrakNY), "Newark Penn Station")
        // Newark, Delaware
        XCTAssertEqual(FerryBuilder.amtrakStationName("Newark Amtrak", source: .amtrakNY), "Newark DE")
        XCTAssertEqual(FerryBuilder.amtrakStationName("Old Saybrook Amtrak Station", source: .amtrakNY), "Old Saybrook")
        // The stations the larger area brings in (names as in Amtrak's data)
        for (raw, name) in [("Paoli Amtrak Station", "Paoli"), ("Exton Amtrak", "Exton"), ("Downingtown Amtrak", "Downingtown"),
                            ("Coatesville Amtrak", "Coatesville"), ("Mystic Amtrak", "Mystic"), ("Wilmington", "Wilmington")] {
            XCTAssertEqual(FerryBuilder.amtrakStationName(raw, source: .amtrakNY), name)
        }
        XCTAssertEqual(FerryFeed.Source.amtrakNY.routeID("42948", name: "Commuter Rail", agency: "1230"), "AMK-SLE")
        XCTAssertEqual(FerryFeed.Source.amtrakNY.routeID("88", name: "Northeast Regional", agency: "51"), "AMK-NER")
        // Agency 1230 means Shore Line East only in Amtrak's package
        XCTAssertEqual(FerryFeed.Source.lirr.routeID("1", name: "Babylon Branch", agency: "1230"), "LIRR-BAB")
        XCTAssertTrue(FerryFeed.sameStationName("Penn Station", "New York Penn Station"))
        XCTAssertFalse(FerryFeed.sameStationName("Penn Station", "Newark Penn Station"))
    }

    // MARK: NJ Transit

    func testNJTransitRail() throws {
        let feed = try FerryBuilder.build([.njTransitRail: njtFiles], now: now)
        // Trains only; the two route_ids of the same line merge into one
        XCTAssertEqual(Set(feed.routes.map(\.id)), ["NJT-MOB", "NJT-NEC"])
        XCTAssertEqual(feed.route("NJT-NEC")?.color, "DD3439")
        XCTAssertEqual(feed.route("NJT-NEC")?.name, "NJ Transit Northeast Corridor")
        XCTAssertEqual(FerryFeed.badge("NJT-NEC"), "NEC")
        XCTAssertTrue(FerryFeed.isRailRoute("NJT-MOB"))
        XCTAssertEqual(Set(feed.piers.map(\.name)),
                       ["Trenton Transit Center", "Newark Penn Station", "Secaucus Junction", "New York Penn Station", "Newark Broad St"])
        // Keep the whole line (whether or not it stops in NYC); drop departures that start more than 45 days out
        XCTAssertEqual(feed.trips.count, 4)
        XCTAssertNil(feed.trips.first { $0.id == "njr:7" })
        // Direction: direction_id 1 is "S"
        XCTAssertEqual(feed.trips.first { $0.id == "njr:1" }?.direction, "S")
        // Leaving Newark Penn at noon: toward New York 12:55, toward Trenton 13:50
        let newark = try XCTUnwrap(feed.piers.first { $0.name == "Newark Penn Station" }?.id)
        let arrivals = feed.arrivals(pierIDs: [newark], from: now, to: now.addingTimeInterval(3 * 3600), realtime: [], now: now)
        XCTAssertEqual(arrivals.count, 2)
        XCTAssertTrue(arrivals.allSatisfy { $0.source == .scheduled })
        let near = feed.stations(near: Coordinate(latitude: 40.7345, longitude: -74.1645), radiusMeters: 300)
        XCTAssertEqual(near.first?.entranceToPlatformSeconds, 120)
        // No live data: the daily check should see whether the calendar covers enough
        XCTAssertTrue(FerryFeed.realtimeSources(routes: feed.routes.map(\.id)).isEmpty)
    }

    func testNJTransitLightRail() throws {
        let feed = try FerryBuilder.build([.njTransitLightRail: njtFiles], now: now)
        XCTAssertEqual(Set(feed.routes.map(\.id)), ["NJL-HBL", "NJL-NLR"])
        XCTAssertEqual(feed.route("NJL-HBL")?.name, "NJ Transit Hudson-Bergen Light Rail")
        XCTAssertEqual(Set(feed.piers.map(\.name)), ["Exchange Place", "Hoboken Terminal", "Newark Penn Station", "Park Avenue Newark"])
        XCTAssertEqual(feed.trips.count, 2)
        let near = feed.stations(near: Coordinate(latitude: 40.716, longitude: -74.034), radiusMeters: 300)
        XCTAssertEqual(near.first?.entranceToPlatformSeconds, 90)
    }

    // MARK: NJ Transit's trains by train number

    /// The sample with a train whose number starts with zeros, a bus standing in for a train ("PJBUS") and a light rail block
    /// written as the real data writes them
    private var njtNumberedFiles: [String: Data] {
        var files = njtFiles
        files["trips.txt"] = d("""
        route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
        10,1,1,NEW YORK PENN STATION,1,4660,1
        10,1,2,TRENTON,0,4661,2
        2,1,3,NEWARK BROAD ST,0,0062,3
        3,1,4,NEWARK BROAD ST,0,PJBUS,3
        4,1,5,HOBOKEN,1,342JC203,4
        13,1,6,PARK AVENUE,0,4665,5
        10,9,7,NEW YORK PENN STATION,1,4666,1
        """)
        return files
    }

    /// The stops and timetable times of the sample's train 4660 (trip 1, Trenton to New York)
    private let train4660: [(stop: String, hour: Int, minute: Int)] = [("148", 12, 10), ("107", 12, 55), ("38174", 13, 5), ("105", 13, 15)]

    /// A time on the sample's day in New York
    private func at(_ hour: Int, _ minute: Int) -> Date {
        Timetable.serviceDayStart(20261014, in: Timetable.timeZone)!.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    /// A live entry as NJ Transit's rail data writes one: its id is the train number, its trip_id is another timetable's, every
    /// stop has a time (a cancelled train's stops are all marked skipped, without times)
    private func njtLive(_ number: String, tripID: String, day: String = "20261014", late: TimeInterval = 0,
                         stops: [(stop: String, hour: Int, minute: Int)] = [], cancelled: Bool = false) -> GTFSRealtimeFeed.TripUpdate {
        .init(entityID: number, tripID: tripID, routeID: "10", startDate: day, isCanceled: cancelled, timestamp: nil,
              stopTimeUpdates: stops.map { stop in
                  let time = cancelled ? nil : at(stop.hour, stop.minute).addingTimeInterval(late)
                  return .init(stopID: stop.stop, arrivalTime: time, departureTime: time, isSkipped: cancelled, hasNoData: false)
              })
    }

    private func njtRealtime(_ updates: [GTFSRealtimeFeed.TripUpdate]) -> FerryRealtime {
        FerryRealtime(feed: GTFSRealtimeFeed(timestamp: now, tripUpdates: updates), fetchedAt: now, source: .njTransitRail)
    }

    /// NJ Transit's public timetable has no trip_short_name: a train's number is its block_id, kept only when it's all digits
    func testNJTransitTrainNumbersComeFromBlockID() throws {
        let feed = try FerryBuilder.build([.njTransitRail: njtNumberedFiles], now: now)
        func number(_ id: String) -> String? { feed.trips.first { $0.id == id }?.number }
        XCTAssertEqual(number("njr:1"), "4660")
        XCTAssertEqual(number("njr:2"), "4661")
        XCTAssertEqual(number("njr:3"), "0062")
        // A bus standing in for a train has a name there, not a number
        XCTAssertNotNil(feed.trips.first { $0.id == "njr:4" })
        XCTAssertNil(number("njr:4"))
        // The light rail keeps none (it isn't matched by number), whatever its block_id looks like
        let light = try FerryBuilder.build([.njTransitLightRail: njtNumberedFiles], now: now)
        XCTAssertEqual(light.trips.count, 2)
        XCTAssertTrue(light.trips.allSatisfy { $0.number == nil })
        // A trip_short_name comes first when the data has one
        var named = njtNumberedFiles
        named["trips.txt"] = d("""
        route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id
        10,1,1,NEW YORK PENN STATION,3920,1,4660,1
        10,1,2,TRENTON,,0,4661,2
        """)
        let withNames = try FerryBuilder.build([.njTransitRail: named], now: now)
        XCTAssertEqual(withNames.trips.first { $0.id == "njr:1" }?.number, "3920")
        XCTAssertEqual(withNames.trips.first { $0.id == "njr:2" }?.number, "4661")
        // Another operator's block_id is never read as a train number
        XCTAssertFalse(FerryFeed.Source.allCases.contains { $0 != .njTransitRail && $0.liveByTrainNumber })
        // The form numbers are compared in: digits only, without leading zeros
        XCTAssertEqual(FerryRealtime.trainNumber("0062"), "62")
        XCTAssertEqual(FerryRealtime.trainNumber("3276"), "3276")
        XCTAssertEqual(FerryRealtime.trainNumber("0000"), "0")
        for other in ["", "PJBUS", "GBUS999", "MNBN BUS", "342JC203", "12 34", "\u{FF11}\u{FF12}\u{FF13}"] {
            XCTAssertNil(FerryRealtime.trainNumber(other), other)
        }
        // Stored data read the old way has no numbers: it's read again once (see testStoredDataRemembersHowItWasBuilt)
        XCTAssertGreaterThanOrEqual(FerryFeed.contentVersion(for: .train), 6)
    }

    /// NJ Transit's live trains go to the timetable's trips by train number, never by trip_id: its live trip_ids are another
    /// copy of the timetable's, and name other trains in the public one
    func testNJTransitTrainsAreLiveByTrainNumberNotTripID() throws {
        let feed = try FerryBuilder.build([.njTransitRail: njtNumberedFiles], now: now)
        let newark = try XCTUnwrap(feed.piers.first { $0.name == "Newark Penn Station" }?.id)
        func arrivals(_ rt: FerryRealtime) -> [Arrival] {
            feed.arrivals(pierIDs: [newark], from: now, to: now.addingTimeInterval(3 * 3600), realtime: [rt], now: now)
        }
        // Train 4660 runs 5 minutes late. Its live trip_id is "2": in this timetable that's the train to Trenton
        let rt = njtRealtime([njtLive("4660", tripID: "2", late: 300, stops: train4660)])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(Array(rt.numbers.keys), ["4660"])
        let both = arrivals(rt)
        XCTAssertEqual(both.count, 2)
        let toNewYork = try XCTUnwrap(both.first { $0.id.hasPrefix("njr:1|") })
        XCTAssertEqual(toNewYork.source, .realtime)
        XCTAssertEqual(toNewYork.arrivalTime, at(13, 0))
        let toTrenton = try XCTUnwrap(both.first { $0.id.hasPrefix("njr:2|") })
        XCTAssertEqual(toTrenton.source, .scheduled)
        XCTAssertEqual(toTrenton.arrivalTime, at(13, 50))
        // A live entry whose trip_id is a timetable trip's but whose number is no train's here: nothing is live
        let stranger = njtRealtime([njtLive("9999", tripID: "1", late: 300, stops: train4660)])
        XCTAssertTrue(arrivals(stranger).allSatisfy { $0.source == .scheduled })
        // Leading zeros don't matter on either side: "62" in the live data is the timetable's "0062", and "04660" is 4660
        let penn = try XCTUnwrap(feed.piers.first { $0.name == "New York Penn Station" }?.id)
        let zeros = njtRealtime([njtLive("62", tripID: "77", late: 120, stops: [("105", 12, 30), ("38174", 12, 50), ("106", 13, 5)]),
                                 njtLive("04660", tripID: "78", late: 60, stops: train4660)])
        let fromPenn = feed.arrivals(pierIDs: [penn], from: now, to: now.addingTimeInterval(3 * 3600), realtime: [zeros], now: now)
        XCTAssertEqual(fromPenn.first { $0.id.hasPrefix("njr:3|") }?.arrivalTime, at(12, 32))
        XCTAssertEqual(fromPenn.first { $0.id.hasPrefix("njr:3|") }?.source, .realtime)
        XCTAssertEqual(arrivals(zeros).first { $0.id.hasPrefix("njr:1|") }?.arrivalTime, at(12, 56))
        // The same number listed more than once (NJ Transit does that, with the same times): the first one counts
        let twice = njtRealtime([njtLive("4660", tripID: "2", late: 300, stops: train4660), njtLive("4660", tripID: "3", late: 900, stops: train4660)])
        XCTAssertEqual(arrivals(twice).first { $0.id.hasPrefix("njr:1|") }?.arrivalTime, at(13, 0))
    }

    /// A train number runs once a day: live data for another day's train isn't this one's, and times hours off aren't used
    func testNJTransitLiveTrainOfAnotherDayIsNotUsed() throws {
        let feed = try FerryBuilder.build([.njTransitRail: njtNumberedFiles], now: now)
        let newark = try XCTUnwrap(feed.piers.first { $0.name == "Newark Penn Station" }?.id)
        func toNewYork(_ rt: FerryRealtime) -> Arrival? {
            feed.arrivals(pierIDs: [newark], from: now, to: now.addingTimeInterval(3 * 3600), realtime: [rt], now: now)
                .first { $0.id.hasPrefix("njr:1|20261014") }
        }
        let yesterday = njtRealtime([njtLive("4660", tripID: "2", day: "20261013", late: 300, stops: train4660)])
        XCTAssertEqual(toNewYork(yesterday)?.source, .scheduled)
        XCTAssertEqual(toNewYork(yesterday)?.arrivalTime, at(12, 55))
        let today = njtRealtime([njtLive("4660", tripID: "2", late: 300, stops: train4660)])
        XCTAssertEqual(toNewYork(today)?.source, .realtime)
        // The right day but four hours off the timetable: some other train's times, not used
        let far = njtRealtime([njtLive("4660", tripID: "2", late: 4 * 3600, stops: train4660)])
        XCTAssertEqual(toNewYork(far)?.source, .scheduled)
        XCTAssertEqual(toNewYork(far)?.arrivalTime, at(12, 55))
    }

    /// A cancelled train (every stop marked skipped) isn't listed, as with the other railroads. The buses that stand in for
    /// trains are in the live data under a name ("PJBUS"), marked cancelled, without stops: they change nothing
    func testNJTransitCancelledTrainsAndSubstituteBuses() throws {
        let feed = try FerryBuilder.build([.njTransitRail: njtNumberedFiles], now: now)
        let newark = try XCTUnwrap(feed.piers.first { $0.name == "Newark Penn Station" }?.id)
        let penn = try XCTUnwrap(feed.piers.first { $0.name == "New York Penn Station" }?.id)
        func ids(_ pier: String, _ rt: FerryRealtime) -> [String] {
            feed.arrivals(pierIDs: [pier], from: now, to: now.addingTimeInterval(3 * 3600), realtime: [rt], now: now)
                .map { String($0.id.prefix { $0 != "|" }) }
        }
        let cancelled = njtRealtime([njtLive("4660", tripID: "2", stops: train4660, cancelled: true)])
        XCTAssertEqual(ids(newark, cancelled), ["njr:2"])
        // The cancelled train of another day leaves today's alone
        let otherDay = njtRealtime([njtLive("4660", tripID: "2", day: "20261013", stops: train4660, cancelled: true)])
        XCTAssertEqual(ids(newark, otherDay), ["njr:1", "njr:2"])
        // Trip 4 is a bus standing in for a train (block_id "PJBUS"); the live data has "PJBUS" and "MNBN BUS" entries marked
        // cancelled, one of them with trip 4's own trip_id: it still leaves from Penn Station at 14:30, on the timetable
        let buses = njtRealtime([njtLive("PJBUS", tripID: "4", cancelled: true), njtLive("MNBN BUS", tripID: "3", cancelled: true)])
        XCTAssertTrue(buses.numbers.isEmpty)
        XCTAssertTrue(buses.trips.isEmpty)
        let fromPenn = feed.arrivals(pierIDs: [penn], from: now, to: now.addingTimeInterval(3 * 3600), realtime: [buses], now: now)
        XCTAssertEqual(fromPenn.map { String($0.id.prefix { $0 != "|" }) }, ["njr:3", "njr:2", "njr:4"])
        XCTAssertTrue(fromPenn.allSatisfy { $0.source == .scheduled })
    }

    /// The rail live data says nothing about the light rail: no realtime is made for it, and its times stay the timetable's
    func testNJTransitLightRailIsNotTouchedByRailLiveData() throws {
        let feed = try FerryBuilder.build([.njTransitLightRail: njtNumberedFiles], now: now)
        // An entry whose trip_id and number are both the light rail trip's own
        let stops: [(stop: String, hour: Int, minute: Int)] = [("36994", 12, 20), ("39348", 12, 30)]
        let update = njtLive("4665", tripID: "5", late: 600, stops: stops)
        // A minimal GTFS-Realtime message (header only)
        let message = Data([0x0A, 0x05, 0x0A, 0x03, 0x32, 0x2E, 0x30])
        XCTAssertTrue(try NJTransitLive.realtime(from: message, fetchedAt: now, sources: [.njTransitLightRail]).isEmpty)
        // Read for the trains, it gives light rail trips nothing either: their IDs aren't the trains'
        let rail = njtRealtime([update])
        let exchange = try XCTUnwrap(feed.piers.first { $0.name == "Exchange Place" }?.id)
        let arrivals = feed.arrivals(pierIDs: [exchange], from: now, to: now.addingTimeInterval(3600), realtime: [rail], now: now)
        XCTAssertEqual(arrivals.count, 1)
        XCTAssertEqual(arrivals.first?.source, .scheduled)
        XCTAssertEqual(arrivals.first?.arrivalTime, at(12, 20))
        XCTAssertFalse(FerryFeed.Source.njTransitLightRail.liveWithAccount)
        XCTAssertTrue(FerryFeed.Source.njTransitRail.liveWithAccount)
    }

    /// The log's line on NJ Transit's live trains: how many the data has, and how many of them are trips of the timetable's
    /// on these days
    func testNJTransitLiveTrainsLogLine() throws {
        let feed = try FerryBuilder.build([.njTransitRail: njtNumberedFiles], now: now)
        // 4660 today (matched), 4661 dated yesterday with today's times (a day off: not used), 9999 not in the timetable, a
        // cancelled 62 (matched: it's today's train), a substitute bus (not a train)
        let rt = njtRealtime([njtLive("4660", tripID: "2", late: 300, stops: train4660),
                              njtLive("4661", tripID: "1", day: "20261013", stops: [("105", 13, 30)]),
                              njtLive("9999", tripID: "3", stops: train4660),
                              njtLive("0062", tripID: "9", stops: [("105", 12, 30)], cancelled: true),
                              njtLive("PJBUS", tripID: "4", cancelled: true)])
        let count = feed.liveTrains(rt, now: now)
        XCTAssertEqual(count.live, 4)
        XCTAssertEqual(count.matched, 2)
        XCTAssertEqual(feed.liveTrainsLogLine(rt, now: now),
                       "NJ Transit Rail live data: 4 trains, 2 of them matched to the timetable's trips on these days")
        // A train that left before midnight is still on yesterday's service day
        let late = njtRealtime([njtLive("4660", tripID: "2", stops: train4660)])
        XCTAssertEqual(feed.liveTrains(late, now: at(24 + 1, 0)).matched, 1)
    }

    // MARK: Amtrak

    func testAmtrakWholeArea() throws {
        let feed = try FerryBuilder.build([.amtrakNY: amtrakFiles], now: now)
        // Only Amtrak trains (no MARC, intercity buses)
        XCTAssertEqual(Set(feed.routes.map(\.id)), ["AMK-NER", "AMK-KEY"])
        XCTAssertEqual(feed.route("AMK-NER")?.color, "00537E")
        XCTAssertEqual(feed.route("AMK-NER")?.name, "Amtrak Northeast Regional")
        // Only stations in the service area: no Washington or Harrisburg. Boston's South Station is in Greater Boston, under the
        // name the MBTA uses for it (Amtrak's data calls all three Boston stations "Boston")
        XCTAssertEqual(Set(feed.piers.map(\.name)),
                       ["Penn Station", "New Rochelle", "Stamford", "New Haven", "Newark Penn Station", "Philadelphia 30th Street", "South Station"])
        let penn = try XCTUnwrap(feed.piers.first { $0.name == "Penn Station" }?.id)
        // 171 (to Boston) boards at Penn Station, headed to Boston; 172 (to Washington) also does, and Newark, the next stop, isn't shown
        let arrivals = feed.arrivals(pierIDs: [penn], from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(3600),
                                     realtime: [], now: now)
        XCTAssertEqual(Set(arrivals.map(\.direction.terminal)), ["Boston", "Washington"])
        XCTAssertEqual(Set(arrivals.map(\.direction.code)).count, 2)
        // Direction by where it's heading: toward Boston is "N", toward Washington is "S"
        XCTAssertEqual(feed.trips.first { $0.id == "amk:171" }?.direction, "N")
        XCTAssertEqual(feed.trips.first { $0.id == "amk:172" }?.direction, "S")
        // Keystone: from Philadelphia to New York, boards at Philadelphia and Newark
        XCTAssertEqual(feed.trips.first { $0.id == "amk:676" }?.stops.count, 3)
        // Times without zero padding ("8:32:00") are readable too; the first stop is Philadelphia
        XCTAssertEqual(feed.trips.first { $0.id == "amk:171" }?.times.first, 8 * 3600 + 32 * 60)
        // Map: stations outside the area aren't drawn
        XCTAssertFalse(feed.map().stations.contains { $0.name.contains("Washington") })
    }

    func testAmtrakNewJerseyAndSameStation() throws {
        let feed = try FerryBuilder.build([.njTransitRail: njtFiles, .amtrakNY: amtrakFiles], now: now)
        XCTAssertTrue(Set(feed.piers.map(\.name)).isSuperset(of: ["Philadelphia 30th Street", "Newark Penn Station", "New York Penn Station", "Penn Station"]))
        XCTAssertFalse(feed.piers.contains { $0.name == "Washington Union Station" })
        // Keystone: from Philadelphia to New York, boards at Newark
        let k = try XCTUnwrap(feed.trips.first { $0.id == "amk:676" })
        XCTAssertEqual(k.direction, "N")
        XCTAssertEqual(k.stops.count, 3)
        // 172 is drop-off only at Newark
        let t172 = try XCTUnwrap(feed.trips.first { $0.id == "amk:172" })
        let nwk = try XCTUnwrap(t172.stops.firstIndex { feed.pier(id: $0)?.name == "Newark Penn Station" })
        XCTAssertFalse(t172.canBoard(at: nwk))
        // The same station of NJ Transit and Amtrak counts as one (same name, or both New York Penn Station, close together)
        let groups = feed.pierGroups()
        let njtPenn = try XCTUnwrap(feed.piers.first { $0.id.hasPrefix("njr:") && $0.name == "New York Penn Station" }?.id)
        let amtPenn = try XCTUnwrap(feed.piers.first { $0.id.hasPrefix("amk:") && $0.name == "Penn Station" }?.id)
        XCTAssertNotNil(groups[njtPenn])
        XCTAssertEqual(groups[njtPenn]?.group, groups[amtPenn]?.group)
        let njtNewark = try XCTUnwrap(feed.piers.first { $0.id.hasPrefix("njr:") && $0.name == "Newark Penn Station" }?.id)
        let amtNewark = try XCTUnwrap(feed.piers.first { $0.id.hasPrefix("amk:") && $0.name == "Newark Penn Station" }?.id)
        XCTAssertEqual(groups[njtNewark]?.group, groups[amtNewark]?.group)
    }

    // MARK: SEPTA Regional Rail

    func testSEPTARegionalRail() throws {
        let feed = try FerryBuilder.build([.septaRail: septaFiles], now: now)
        // Its own three-letter line codes and color, with live data (free, no key)
        XCTAssertEqual(Set(feed.routes.map(\.id)), ["SRR-TRE", "SRR-CHW", "SRR-WIL"])
        XCTAssertEqual(feed.route("SRR-TRE")?.name, "SEPTA Trenton Line")
        XCTAssertEqual(FerryFeed.routeName("SRR-WIL"), "SEPTA Wilmington/Newark Line")
        XCTAssertEqual(feed.route("SRR-WIL")?.color, "4F758B")
        XCTAssertEqual(FerryFeed.badge("SRR-CHW"), "CHW")
        XCTAssertTrue(FerryFeed.isRailRoute("SRR-TRE"))
        XCTAssertTrue(feed.hasRealtime(route: "SRR-TRE"))
        XCTAssertEqual(FerryFeed.realtimeSources(routes: feed.routes.map(\.id)), [.septaRail])
        XCTAssertEqual(FerryFeed.Source.septaRail.system, .train)
        XCTAssertFalse(FerryFeed.Source.septaRail.needsAccount)
        XCTAssertEqual(FerryFeed.Source.septaRail.boardingSeconds, 120)
        // The stations it shares with Amtrak and NJ Transit take their names; North Philadelphia's two platforms get one name
        XCTAssertEqual(Set(feed.piers.map(\.name)), ["Philadelphia 30th Street", "Suburban Station", "North Philadelphia", "Cornwells Heights",
                                                     "Trenton", "Wilmington", "Newark DE"])
        XCTAssertNil(feed.pier(id: "srr:90004")?.code)
        // Train numbers as in the data; the calendar starting in January is more than 45 days out, so its trip isn't kept
        let trip = try XCTUnwrap(feed.trips.first { $0.id == "srr:TRE9714_20261005_WK" })
        XCTAssertEqual(trip.number, "TRE9714")
        XCTAssertNil(feed.trips.first { $0.id == "srr:WIL9232_20270104_LATER" })
        XCTAssertEqual(feed.trips.count, 4)
        XCTAssertEqual(feed.versions["srr"], "v202610050")
        // direction_id 0 (toward Center City) is "N", 1 is "S"
        XCTAssertEqual(trip.direction, "S")
        XCTAssertEqual(feed.trips.first { $0.id == "srr:TRE9729_20261005_WK" }?.direction, "N")
        // Live data uses the timetable's trip_id and names each stop only by its stop_sequence, with a delay: 4 minutes late at
        // North Philadelphia (stop_sequence 3), carried on to Cornwells Heights
        let dayStart = Timetable.serviceDayStart(20261014, in: Timetable.timeZone)!
        XCTAssertEqual(trip.sequences, [1, 2, 3, 4, 5])
        let live = FerryRealtime(timestamp: now, trips: ["TRE9714_20261005_WK": .init(stopTimes: [.init(stopID: "", delay: 240, sequence: 3)])],
                                 fetchedAt: now, source: .septaRail)
        XCTAssertEqual(live.delays(for: trip, dayStart: dayStart, day: 20261014)?.known.first?.index, 2)
        // Operators whose trips don't keep stop_sequence don't match a stop by it
        var plain = trip
        plain.sequences = nil
        XCTAssertNil(live.delays(for: plain, dayStart: dayStart, day: 20261014))
        let arrivals = feed.arrivals(pierIDs: ["srr:90706"], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [live], now: now)
        let toTrenton = try XCTUnwrap(arrivals.first { $0.route == "SRR-TRE" && $0.direction.code == "S" })
        XCTAssertEqual(toTrenton.source, .realtime)
        XCTAssertEqual(toTrenton.arrivalTime, dayStart.addingTimeInterval(12 * 3600 + 39 * 60))
        XCTAssertEqual(toTrenton.direction.terminal, "Trenton")
        // The other way has no live data: the timetable's time
        let toCenterCity = try XCTUnwrap(arrivals.first { $0.route == "SRR-TRE" && $0.direction.code == "N" })
        XCTAssertEqual(toCenterCity.source, .scheduled)
        // SEPTA numbers the stops along a train's whole run, which can go on from one line to the next (this trip's are 16 to 18).
        // 0 is a train it has no position for yet, and a number before the trip's first a stop the train makes before this trip
        // starts: its delay counts from the first stop, as does a prediction naming no stop at all. A number after the trip's last is
        // a stop of the train's next trip: nothing
        let wilmington = try XCTUnwrap(feed.trips.first { $0.id == "srr:WIL9230_20261005_WK" })
        XCTAssertEqual(wilmington.sequences, [16, 17, 18])
        func wil(_ sequence: Int?, _ delay: TimeInterval) -> FerryRealtime {
            FerryRealtime(timestamp: now, trips: ["WIL9230_20261005_WK": .init(stopTimes: [.init(stopID: "", delay: delay, sequence: sequence)])],
                          fetchedAt: now, source: .septaRail)
        }
        XCTAssertEqual(wil(17, 300).delays(for: wilmington, dayStart: dayStart, day: 20261014)?.known.map(\.index), [1])
        XCTAssertEqual(wil(0, 300).delays(for: wilmington, dayStart: dayStart, day: 20261014)?.known.map(\.index), [0])
        XCTAssertEqual(wil(12, 300).delays(for: wilmington, dayStart: dayStart, day: 20261014)?.known.map(\.index), [0])
        XCTAssertEqual(wil(nil, 300).delays(for: wilmington, dayStart: dayStart, day: 20261014)?.known.map(\.index), [0])
        XCTAssertNil(wil(40, 300).delays(for: wilmington, dayStart: dayStart, day: 20261014))
        // Counting from the first stop takes only a delay: a time with no stop of this trip named would be some other stop's
        for sequence in [nil, 0, 12] as [Int?] {
            let timed = FerryRealtime(timestamp: now, trips: ["WIL9230_20261005_WK": .init(stopTimes: [
                .init(stopID: "", time: dayStart.addingTimeInterval(13 * 3600), sequence: sequence)])], fetchedAt: now, source: .septaRail)
            XCTAssertNil(timed.delays(for: wilmington, dayStart: dayStart, day: 20261014))
        }
        let atThirtieth = feed.arrivals(pierIDs: ["srr:90004"], from: now, to: now.addingTimeInterval(3600), realtime: [wil(0, 300)], now: now)
        let toNewark = try XCTUnwrap(atThirtieth.first { $0.route == "SRR-WIL" })
        XCTAssertEqual(toNewark.source, .realtime)
        XCTAssertEqual(toNewark.arrivalTime, dayStart.addingTimeInterval(12 * 3600 + 35 * 60))
        // A canceled train (no stops listed) isn't shown
        let canceled = FerryRealtime(timestamp: now, trips: ["WIL9230_20261005_WK": .init(stopTimes: [], canceled: true)],
                                     fetchedAt: now, source: .septaRail)
        XCTAssertFalse(feed.arrivals(pierIDs: ["srr:90004"], from: now, to: now.addingTimeInterval(3600), realtime: [canceled], now: now)
            .contains { $0.route == "SRR-WIL" })
    }

    /// Where SEPTA shares a station with Amtrak and NJ Transit it's one station under their name: 30th Street (NJ Transit's point is 58 m
    /// away, Amtrak's 128 m), Trenton (NJ Transit's at the same point, Amtrak's 70 m away), Cornwells Heights (Amtrak's 200 m away),
    /// North Philadelphia (both SEPTA platforms and Amtrak's), Wilmington and Newark DE
    func testSEPTASharesStationsWithAmtrakAndNJTransit() throws {
        func adding(_ rows: [String], to file: String, of files: [String: Data]) -> Data {
            Data((String(decoding: files[file]!, as: UTF8.self) + "\n" + rows.joined(separator: "\n") + "\n").utf8)
        }
        var njt = njtFiles
        njt["routes.txt"] = adding(["1,NJT,ACRL,Atlantic City Rail Line,2,,075AAA"], to: "routes.txt", of: njtFiles)
        njt["stops.txt"] = adding(["43599,95043,ATLANTIC CITY RAIL TERMINAL,,39.363799,-74.441619,5"], to: "stops.txt", of: njtFiles)
        njt["trips.txt"] = adding(["1,1,8,ATLANTIC CITY,0,4667,6"], to: "trips.txt", of: njtFiles)
        njt["stop_times.txt"] = adding(["8,12:40:00,12:40:00,1,1,0,0,0", "8,14:10:00,14:10:00,43599,2,0,0,60"],
                                       to: "stop_times.txt", of: njtFiles)
        var amtrak = amtrakFiles
        amtrak["stops.txt"] = adding(["TRE,TRE,Trenton,,,40.219011,-74.75444",
                                      "CWH,CWH,Cornwells Heights Amtrak,,,40.071663,-74.952187",
                                      "PHN,PHN,North Philadelphia Amtrak Station,,,39.99678,-75.155114",
                                      "WIL,WIL,Wilmington,,,39.737263,-75.551095",
                                      "NRK,NRK,Newark Amtrak,,,39.669686,-75.753513"], to: "stops.txt", of: amtrakFiles)
        amtrak["trips.txt"] = adding(["88,S1,640,640,0,,New York"], to: "trips.txt", of: amtrakFiles)
        amtrak["stop_times.txt"] = adding(["640,11:00:00,11:00:00,NRK,1,0,0,1", "640,11:15:00,11:16:00,WIL,2,0,0,1",
                                           "640,11:45:00,11:47:00,PHL,3,0,0,1", "640,11:55:00,11:55:00,PHN,4,0,0,1",
                                           "640,12:05:00,12:05:00,CWH,5,0,0,1", "640,12:25:00,12:26:00,TRE,6,0,0,1",
                                           "640,13:30:00,13:30:00,NYP,7,0,0,1"], to: "stop_times.txt", of: amtrakFiles)
        let feed = try FerryBuilder.build([.njTransitRail: njt, .amtrakNY: amtrak, .septaRail: septaFiles], now: now)
        let groups = feed.pierGroups()
        // 30th Street: all three, under the name NJ Transit and Amtrak use
        XCTAssertNotNil(groups["srr:90004"])
        XCTAssertEqual(groups["srr:90004"]?.group, groups["njr:1"]?.group)
        XCTAssertEqual(groups["srr:90004"]?.group, groups["amk:PHL"]?.group)
        XCTAssertEqual(groups["srr:90004"]?.name, "Philadelphia 30th Street")
        // Trenton: NJ Transit's name, the first operator in the list
        XCTAssertNotNil(groups["srr:90701"])
        XCTAssertEqual(groups["srr:90701"]?.group, groups["njr:148"]?.group)
        XCTAssertEqual(groups["srr:90701"]?.group, groups["amk:TRE"]?.group)
        XCTAssertEqual(groups["srr:90701"]?.name, "Trenton Transit Center")
        // Cornwells Heights: 200 m apart with the same name
        XCTAssertNotNil(groups["srr:90706"])
        XCTAssertEqual(groups["srr:90706"]?.group, groups["amk:CWH"]?.group)
        XCTAssertEqual(groups["srr:90706"]?.name, "Cornwells Heights")
        // North Philadelphia: SEPTA's two platforms and Amtrak's
        XCTAssertNotNil(groups["srr:90810"])
        XCTAssertEqual(groups["srr:90711"]?.group, groups["amk:PHN"]?.group)
        XCTAssertEqual(groups["srr:90810"]?.group, groups["amk:PHN"]?.group)
        XCTAssertEqual(groups["srr:90810"]?.name, "North Philadelphia")
        // Wilmington and Newark DE
        XCTAssertNotNil(groups["srr:90203"])
        XCTAssertEqual(groups["srr:90203"]?.group, groups["amk:WIL"]?.group)
        XCTAssertNotNil(groups["srr:90201"])
        XCTAssertEqual(groups["srr:90201"]?.group, groups["amk:NRK"]?.group)
        XCTAssertEqual(groups["srr:90201"]?.name, "Newark DE")
        // Suburban Station is SEPTA's alone, and different stations stay apart
        XCTAssertNil(groups["srr:90005"])
        XCTAssertNotEqual(groups["srr:90701"]?.group, groups["srr:90004"]?.group)
        // Near 30th Street it's one station with all three operators' trains
        let near = feed.stations(near: Coordinate(latitude: 39.9562, longitude: -75.1818), radiusMeters: 300)
        XCTAssertEqual(Set(near.map(\.id)), ["srr:90004", "njr:1", "amk:PHL"])
        XCTAssertEqual(Set(near.compactMap(\.complexID)).count, 1)
        XCTAssertTrue(near.allSatisfy { $0.name == "Philadelphia 30th Street" })
    }

    // MARK: SEPTA Metro and PATCO

    /// SEPTA's bus package as in the real data: its Metro lines (subway 1, trolley 0) with its buses (3) and trackless trolleys (11),
    /// line codes as route_ids, notes for SEPTA's own use in stop names ("- FS", "- MBNS 2"), platforms named after their lines
    /// ("Olney Transit Center - B2 & B3"), headsigns riders see ("NRG", "63rd-Girard") and no trip_short_name. Positions as in the real data
    private var septaMetroFiles: [String: Data] {
        [
            "agency.txt": d("""
            agency_id,agency_name,agency_url,agency_timezone,agency_lang,agency_phone,agency_fare_url
            SEPTA,SEPTA,https://www.septa.org/,America/New_York,en,,
            """),
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_url,route_color,route_text_color,route_sort_order,network_id
            L1,SEPTA,L1,Market-Frankford Line,1,,0097D6,FFFFFF,,
            B1,SEPTA,B1,Broad Street Line Local,1,,F26100,FFFFFF,,
            G1,SEPTA,G1,Girard Avenue Trolley,0,,FFD700,000000,,
            17,SEPTA,17,20th-Johnston to Front-Market,3,,,,,
            66,SEPTA,66,Frankford-Dyre to Frankford-Knights,11,,,,,
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_lat,stop_lon,zone_id,stop_url,location_type,parent_station,wheelchair_boarding,level_id
            416,,69th St Transit Center,39.962338,-75.258555,1,,0,31034,1,
            1392,,15th St/City Hall,39.952573,-75.165286,1,,0,33034,1,
            2457,,8th-Market,39.951102,-75.153589,1,,0,,1,
            61,,Frankford Transit Center,40.022929,-75.077861,1,,0,31033,1,
            3001,,Fern Rock Transit Center,40.041420,-75.136800,1,,0,,1,
            3002,,Olney Transit Center - B2 & B3,40.038960,-75.144620,1,,0,,1,
            3003,,NRG Station,39.905580,-75.173890,1,,0,,1,
            4001,,Girard Av & 63rd St - MBNS 2,39.972300,-75.246200,1,,0,,1,
            4002,,Girard Av & 40th St - FS,39.973600,-75.202300,1,,0,,1,
            4003,,Richmond St & Westmoreland St,39.984300,-75.100500,1,,0,,1,
            5001,,20th St & Johnston St - FS,39.920100,-75.179800,1,,0,,1,
            5002,,Front St & Market St - NS,39.949900,-75.142300,1,,0,,1,
            32723,,End of WB trip on EB plat - Not a stop,39.962706,-75.259995,1,,0,,1,
            30855,,Employee Platform - Employees Only,39.964477,-75.262660,1,,0,,1,
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id,wheelchair_accessible,bikes_allowed
            L1,16,699524,Frankford Transit Center,,0,70002,,1,1
            L1,16,699600,69th St Transit Center,,1,70003,,1,1
            B1,16,710001,NRG,,1,,,1,1
            G1,16,694316,63rd-Girard,,0,9001,,1,2
            17,16,720936,Front-Market,,0,7301,,1,1
            66,16,730001,Frankford-Knights,,0,,,1,1
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,stop_headsign,pickup_type,drop_off_type,shape_dist_traveled,timepoint
            699524,12:00:00,12:00:00,416,1,,,,,1
            699524,12:15:00,12:15:00,1392,2,,,,,1
            699524,12:17:00,12:17:00,2457,3,,,,,1
            699524,12:40:00,12:40:00,61,4,,,,,1
            699600,12:05:00,12:05:00,61,1,,,,,1
            699600,12:28:00,12:28:00,2457,2,,,,,1
            699600,12:30:00,12:30:00,1392,3,,,,,1
            699600,12:45:00,12:45:00,416,4,,,,,1
            699600,12:48:00,12:48:00,32723,5,,,,,1
            710001,12:00:00,12:00:00,3001,1,,,,,1
            710001,12:01:00,12:01:00,30855,2,,,,,1
            710001,12:03:00,12:03:00,3002,3,,,,,1
            710001,12:30:00,12:30:00,3003,4,,,,,1
            694316,12:00:00,12:00:00,4003,1,,,,,1
            694316,12:20:00,12:20:00,4002,2,,,,,1
            694316,12:40:00,12:40:00,4001,3,,,,,1
            720936,12:00:00,12:00:00,5001,1,,,,,1
            720936,12:30:00,12:30:00,5002,2,,,,,1
            730001,12:00:00,12:00:00,61,1,,,,,1
            730001,12:20:00,12:20:00,5002,2,,,,,1
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            16,1,1,1,1,1,0,0,20261005,20270220
            """),
            "feed_info.txt": d("""
            feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date,feed_version
            SEPTA,https://www.septa.org/,en,20261005,20270220,202610260
            """),
        ]
    }

    /// PATCO as in the real data: one route (route_id "2", long name "High Speed Line"), westbound trips headed "Philadelphia"
    private var patcoFiles: [String: Data] {
        [
            "agency.txt": d("""
            agency_id,agency_name,agency_url,agency_timezone,agency_lang,agency_phone
            PATCO,Port Authority Transit Corporation,https://www.ridepatco.org/,America/New_York,en,
            """),
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color,route_sort_order,continuous_pickup,continuous_drop_off
            2,PATCO,PATCO,High Speed Line,,1,,BC0035,FFFFFF,,,
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,zone_id,stop_url,location_type,parent_station,stop_timezone,wheelchair_boarding,platform_code
            1,,Lindenwold,,39.833962,-75.000664,,,0,,,1,
            8,,Broadway,,39.943135,-75.120364,,,0,,,1,
            11,,8th and Market,,39.950979,-75.153515,,,0,,,1,
            14,,15-16th and Locust,,39.948634,-75.167792,,,0,,,1,
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id,wheelchair_accessible,bikes_allowed
            2,194 Weekday,Weekday Westbound_T01,Philadelphia,0,,2,1,1
            2,194 Weekday,Weekday Eastbound_T02,Lindenwold,1,,2,1,1
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            Weekday Westbound_T01,12:00:00,12:00:00,1,1
            Weekday Westbound_T01,12:15:00,12:15:00,8,2
            Weekday Westbound_T01,12:20:00,12:20:00,11,3
            Weekday Westbound_T01,12:25:00,12:25:00,14,4
            Weekday Eastbound_T02,12:30:00,12:30:00,14,1
            Weekday Eastbound_T02,12:35:00,12:35:00,11,2
            Weekday Eastbound_T02,12:40:00,12:40:00,8,3
            Weekday Eastbound_T02,12:55:00,12:55:00,1,4
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            194 Weekday,1,1,1,1,1,0,0,20260521,20261231
            """),
        ]
    }

    func testSEPTAMetro() throws {
        let feed = try FerryBuilder.build([.septaMetro: septaMetroFiles], now: now)
        // Its subway and trolley lines by their codes, in its own colors; the buses and trackless trolleys in the package are left out
        XCTAssertEqual(Set(feed.routes.map(\.id)), ["SMT-L1", "SMT-B1", "SMT-G1"])
        XCTAssertEqual(feed.route("SMT-L1")?.color, "0097D6")
        XCTAssertEqual(FerryFeed.badge("SMT-G1"), "G1")
        XCTAssertTrue(FerryFeed.isRailRoute("SMT-L1"))
        XCTAssertTrue(feed.hasRealtime(route: "SMT-B1"))
        XCTAssertEqual(FerryFeed.realtimeSources(routes: feed.routes.map(\.id)), [.septaMetro])
        XCTAssertEqual(FerryFeed.Source.septaMetro.system, .lightRail)
        XCTAssertEqual(FerryFeed.Source.septaMetro.shortName, "SEPTA")
        XCTAssertFalse(FerryFeed.Source.septaMetro.needsAccount)
        XCTAssertEqual(FerryFeed.Source.septaMetro.boardingSeconds, 90)
        XCTAssertEqual(FerryFeed.Source.septaMetro.url, FerryFeed.septaBusURL)
        XCTAssertNil(feed.pier(id: "smt:5001"))
        XCTAssertEqual(feed.trips.count, 4)
        XCTAssertEqual(feed.versions["smt"], "202610260")
        // Stop names without SEPTA's notes for its own use, nor the lines a platform is for
        XCTAssertEqual(feed.pier(id: "smt:4002")?.name, "Girard Av & 40th St")
        XCTAssertEqual(feed.pier(id: "smt:4001")?.name, "Girard Av & 63rd St")
        XCTAssertEqual(feed.pier(id: "smt:3002")?.name, "Olney Transit Center")
        XCTAssertEqual(feed.pier(id: "smt:1392")?.name, "15th St/City Hall")
        // Points riders can't use are left out: where westbound trains end after 69th St, and a platform for employees only
        XCTAssertNil(feed.pier(id: "smt:32723"))
        XCTAssertNil(feed.pier(id: "smt:30855"))
        XCTAssertEqual(feed.trips.first { $0.id == "smt:699600" }?.stops.last, "smt:416")
        XCTAssertEqual(feed.trips.first { $0.id == "smt:710001" }?.stops, ["smt:3001", "smt:3002", "smt:3003"])
        XCTAssertTrue(FerryBuilder.isNotForRiders("96 Signal - not a stop"))
        XCTAssertFalse(FerryBuilder.isNotForRiders("UPS Employee Parking Lot 1"))
        // The destination riders see: the trip's headsign where it differs from the last stop's name
        let dayStart = Timetable.serviceDayStart(20261014, in: Timetable.timeZone)!
        let from = dayStart.addingTimeInterval(11 * 3600), to = dayStart.addingTimeInterval(14 * 3600)
        let olney = feed.arrivals(pierIDs: ["smt:3002"], from: from, to: to, realtime: [], now: now)
        XCTAssertEqual(olney.first?.direction.terminal, "NRG")
        let girard = feed.arrivals(pierIDs: ["smt:4002"], from: from, to: to, realtime: [], now: now)
        XCTAssertEqual(girard.first?.direction.terminal, "63rd-Girard")
        let market = feed.arrivals(pierIDs: ["smt:2457"], from: from, to: to, realtime: [], now: now)
        XCTAssertEqual(Set(market.map(\.direction.terminal)), ["Frankford Transit Center", "69th St Transit Center"])
        // Live data uses the timetable's trip_id: 3 minutes late at 15th St, carried on to 8th-Market
        let trip = try XCTUnwrap(feed.trips.first { $0.id == "smt:699524" })
        let live = FerryRealtime(timestamp: now, trips: ["699524": .init(stopTimes: [.init(stopID: "1392", delay: 180)])],
                                 fetchedAt: now, source: .septaMetro)
        XCTAssertEqual(live.delays(for: trip, dayStart: dayStart, day: 20261014)?.known.first?.index, 1)
        let east = feed.arrivals(pierIDs: ["smt:2457"], from: now, to: now.addingTimeInterval(3600), realtime: [live], now: now)
            .first { $0.direction.terminal == "Frankford Transit Center" }
        XCTAssertEqual(east?.source, .realtime)
        XCTAssertEqual(east?.arrivalTime, dayStart.addingTimeInterval(12 * 3600 + 20 * 60))
    }

    // MARK: MBTA

    /// The MBTA's one package as in the real data (rows from it, times moved to midday): its subway (1) and trolley lines (0), its
    /// trains (2, with the CapeFLYER under another agency), its ferries (4) and its buses (3: the Silver Line and a shuttle bus that
    /// replaces trains), stations as parents (location_type 1) of their platforms, and a feed_version with commas
    private var mbtaFiles: [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color,route_sort_order,route_fare_class,line_id,listed_route,network_id
            Red,1,,Red Line,Rapid Transit,1,,DA291C,FFFFFF,10010,Rapid Transit,line-Red,,rapid_transit
            Mattapan,1,,Mattapan Line,Rapid Transit,0,,DA291C,FFFFFF,10011,Rapid Transit,line-Mattapan,,m_rapid_transit
            Green-B,1,B,Green Line B,Rapid Transit,0,,00843D,FFFFFF,10032,Rapid Transit,line-Green,,rapid_transit
            741,1,SL1,Logan Airport Terminals - South Station,Frequent Bus,3,,7C878E,FFFFFF,10051,Rapid Transit,line-SLWaterfront,,sl_rapid_transit
            CR-Fitchburg,1,,Fitchburg Line,Regional Rail,2,,80276C,FFFFFF,20003,Commuter Rail,line-Fitchburg,,commuter_rail
            CapeFlyer,3,,CapeFLYER,Regional Rail,2,,006595,FFFFFF,21000,Special,line-CapeFlyer,,cape_flyer
            Boat-F1,1,,Hingham Ferry,Ferry,4,,008EAA,FFFFFF,30002,Ferry,line-Boat-F1,,ferry_f1f2h
            Shuttle-ForgeParkNorwoodCentral,1,Franklin Line Shuttle,Forge Park/495 - Norwood Central,Rail Replacement Bus,3,,FFC72C,000000,61740,Free,line-Franklin,1,rail_replacement_bus
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_desc,platform_code,platform_name,stop_lat,stop_lon,zone_id,stop_address,stop_url,level_id,location_type,parent_station,wheelchair_boarding,municipality,on_street,at_street,vehicle_type
            place-alfcl,,Alewife,,,,42.396148,-71.140698,,,,,1,,1,Cambridge,,,
            70061,70061,Alewife,Alewife - Red Line,,Red Line,42.396148,-71.140698,RapidTransit,,,,0,place-alfcl,1,Cambridge,,,1
            70093,70093,Ashmont,Ashmont - Red Line - Exit Only,,Exit Only,42.284508,-71.063833,RapidTransit,,,,0,place-asmnl,1,Boston,,,1
            70261,70261,Ashmont,Ashmont - Mattapan Line,,Mattapan Line,42.283768,-71.063191,RapidTransit,,,,0,place-asmnl,1,Boston,,,0
            70275,70275,Mattapan,Mattapan - Exit Only,,Exit Only,42.267625,-71.092389,RapidTransit,,,,0,place-matt,1,Boston,,,0
            170137,170137,Babcock Street,Babcock Street - Green Line - (B) Boston College,,Boston College,42.351695,-71.120257,RapidTransit,,,,0,place-babck,1,Boston,,,0
            70107,70107,Boston College,Boston College - Green Line - Exit Only,,Exit Only,42.34024,-71.166849,RapidTransit,,,,0,place-lake,1,Boston,,,0
            BNT-0000,,North Station,North Station - Commuter Rail,,Commuter Rail,42.366417,-71.062326,CR-zone-1A,,,,0,place-north,1,Boston,,,2
            FR-3338-CS,,Wachusett,Wachusett - Track 3 (All Trains),3,Track 3 (All Trains),42.553477,-71.848488,CR-zone-8,,,,0,place-FR-3338,1,Fitchburg,,,2
            NEC-2287,,South Station,South Station - Commuter Rail,,Commuter Rail,42.351497,-71.055059,CR-zone-1A,,,,0,place-sstat,1,Boston,,,2
            CM-0790-S,,Hyannis,Hyannis - Track 1 (All Trains),1,Track 1 (All Trains),41.660225,-70.276583,,,,,0,place-CM-0790,1,Barnstable,,,2
            Boat-Rowes,,Rowes Wharf,Rowes Wharf - Gate C,C,Gate C,42.35558,-71.04902,Boat-Rowes,,,,0,,1,Boston,,,4
            Boat-Hingham,,Hingham (Hewitts Cove),Hingham (Hewitts Cove) - Hingham/Hull Ferry,,Hingham/Hull Ferry,42.25415,-70.91985,Boat-Hingham,,,,0,,1,Hingham,,,4
            84611,84611,South Station,South Station - Silver Line - Airport,,Airport,42.352271,-71.055242,,,,,0,place-sstat,1,Boston,,,3
            17091,17091,Terminal A,Terminal A - Silver Line - South Station,,South Station,42.364612,-71.020862,,,,,0,,1,Boston,,,3
            FB-0148-B1,,Norwood Central - Broadway @ Norwood Central Station,,,Commuter Rail Shuttle,42.18874,-71.20004,,,,,0,place-FB-0148,1,Norwood,,,3
            FB-0303-B,,Forge Park/495 - South Parking Lot,,,Commuter Rail Shuttle,42.089825,-71.439075,,,,,0,place-FB-0303,1,Franklin,,,3
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id,wheelchair_accessible,trip_route_type,route_pattern_id,bikes_allowed
            Red,16,80722172,Ashmont,,0,,,1,,Red-1-0,0
            Mattapan,16,77713981,Mattapan,,0,,,1,,Mattapan-_-0,0
            Green-B,16,79234356,Boston College,,0,,,1,,Green-B-812-0,0
            741,16,78612827,Logan Airport,,0,,,1,,741-_-0,0
            CR-Fitchburg,16,WRMLCulverts-885467-4515,Wachusett,4515,0,,,1,,CR-Fitchburg-C1-0,1
            CapeFlyer,16,canonical-CapeFlyer-C1-0,Hyannis,C9001,0,,,1,,CapeFlyer-C1-0,1
            Boat-F1,16,Boat-F1-0645-Rowes-F1-A-AM-Weekday-Fall-26,Hingham,,0,,,1,,Boat-F1-A-0,1
            Shuttle-ForgeParkNorwoodCentral,16,CR-Fall2026FranklinPhase2-Shuttle-ForgeParkNorwoodCentral-0-08:19:00,Forge Park (Shuttle),B7005,0,,,1,,Shuttle-ForgeParkNorwoodCentral-0-0,0
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,stop_headsign,pickup_type,drop_off_type,timepoint,checkpoint_id,continuous_pickup,continuous_drop_off
            80722172,12:18:00,12:18:00,70061,1,,0,1,1,,1,1
            80722172,12:52:00,12:52:00,70093,170,,1,0,1,,1,1
            77713981,12:11:00,12:11:00,70261,1,,0,1,1,,1,1
            77713981,12:22:00,12:22:00,70275,8,,1,0,1,,1,1
            79234356,12:55:00,12:55:00,170137,180,,0,0,1,,1,1
            79234356,13:19:00,13:19:00,70107,310,,1,0,1,,1,1
            WRMLCulverts-885467-4515,12:40:00,12:40:00,BNT-0000,0,,0,1,1,,1,1
            WRMLCulverts-885467-4515,14:16:00,14:16:00,FR-3338-CS,160,,1,0,1,,1,1
            canonical-CapeFlyer-C1-0,12:00:00,12:00:00,NEC-2287,0,,0,1,1,,1,1
            canonical-CapeFlyer-C1-0,14:27:00,14:27:00,CM-0790-S,7,,1,0,1,,1,1
            Boat-F1-0645-Rowes-F1-A-AM-Weekday-Fall-26,12:45:00,12:45:00,Boat-Rowes,0,,0,1,1,,1,1
            Boat-F1-0645-Rowes-F1-A-AM-Weekday-Fall-26,13:20:00,13:20:00,Boat-Hingham,1,,1,0,1,,1,1
            78612827,12:48:00,12:48:00,84611,1,,0,1,1,,1,1
            78612827,13:06:00,13:06:00,17091,5,,1,0,1,,1,1
            CR-Fall2026FranklinPhase2-Shuttle-ForgeParkNorwoodCentral-0-08:19:00,12:19:00,12:19:00,FB-0148-B1,1,,0,1,1,,1,1
            CR-Fall2026FranklinPhase2-Shuttle-ForgeParkNorwoodCentral-0-08:19:00,13:10:00,13:10:00,FB-0303-B,6,,1,0,1,,1,1
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            16,1,1,1,1,1,0,0,20261005,20270220
            """),
            "feed_info.txt": d("""
            feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date,feed_version,feed_contact_email,feed_id
            MBTA,http://www.mbta.com,EN,20261005,20270220,"Fall 2026, 2026-11-10T15:27:56+00:00, version D",,mbta-ma-us
            """),
        ]
    }

    func testMBTA() throws {
        let feed = try FerryBuilder.build([.mbtaSubway: mbtaFiles, .mbtaRail: mbtaFiles, .mbtaFerry: mbtaFiles], now: now)
        // Each mode reads its own route types from the one package; the buses (the Silver Line, the shuttle buses) are the bus list's
        XCTAssertEqual(Set(feed.routes.map(\.id)), ["MBS-RL", "MBS-M", "MBS-B", "MBR-FBG", "MBR-CF", "MBF-F1"])
        XCTAssertEqual(feed.trips.count, 6)
        XCTAssertNil(feed.pier(id: "mbs:84611"))
        XCTAssertNil(feed.pier(id: "mbr:FB-0148-B1"))
        // Badges as on the MBTA's own signs, in its colors; the CapeFLYER by its own name
        XCTAssertEqual(["MBS-RL", "MBS-M", "MBS-B", "MBR-FBG", "MBF-F1"].map(FerryFeed.badge), ["RL", "M", "B", "FBG", "F1"])
        XCTAssertEqual(feed.route("MBS-RL")?.color, "DA291C")
        XCTAssertEqual(feed.route("MBS-B")?.color, "00843D")
        XCTAssertEqual(FerryFeed.routeName("MBR-FBG"), "MBTA Fitchburg Line")
        XCTAssertEqual(FerryFeed.routeName("MBR-CF"), "CapeFLYER")
        XCTAssertEqual(FerryFeed.routeName("MBF-F1"), "MBTA Hingham Ferry")
        XCTAssertEqual(FerryFeed.Source.of(route: "MBS-M"), .mbtaSubway)
        // Subway and trolley lines are shown under Subway, Commuter Rail under Train, ferries under Ferry; all with free live data
        XCTAssertEqual([FerryFeed.Source.mbtaSubway, .mbtaRail, .mbtaFerry].map(\.system), [.lightRail, .train, .ferry])
        XCTAssertTrue(feed.routes.allSatisfy { feed.hasRealtime(route: $0.id) })
        XCTAssertFalse(FerryFeed.Source.mbtaSubway.needsAccount)
        // Platforms, not their parent stations; one version for the package, commas and all
        XCTAssertNil(feed.pier(id: "mbs:place-alfcl"))
        XCTAssertEqual(feed.pier(id: "mbs:70061")?.name, "Alewife")
        XCTAssertEqual(feed.versions["mbs"], "Fall 2026, 2026-11-10T15:27:56+00:00, version D")
        // Departures with where they go: a train's headsign, a ferry's last pier
        let dayStart = Timetable.serviceDayStart(20261014, in: Timetable.timeZone)!
        let alewife = feed.arrivals(pierIDs: ["mbs:70061"], from: dayStart.addingTimeInterval(11 * 3600),
                                    to: dayStart.addingTimeInterval(14 * 3600), realtime: [], now: now)
        XCTAssertEqual(alewife.map(\.direction.terminal), ["Ashmont"])
        let rowes = feed.arrivals(pierIDs: ["mbf:Boat-Rowes"], from: dayStart.addingTimeInterval(11 * 3600),
                                  to: dayStart.addingTimeInterval(14 * 3600), realtime: [], now: now)
        XCTAssertEqual(rowes.map(\.direction.terminal), ["Hingham (Hewitts Cove)"])
    }

    func testPATCO() throws {
        let feed = try FerryBuilder.build([.patco: patcoFiles], now: now)
        XCTAssertEqual(feed.routes.map(\.id), ["PAT-PATCO"])
        XCTAssertEqual(FerryFeed.badge("PAT-PATCO"), "PATCO")
        XCTAssertEqual(feed.route("PAT-PATCO")?.color, "BC0035")
        XCTAssertFalse(feed.hasRealtime(route: "PAT-PATCO"))
        XCTAssertNil(FerryFeed.Source.patco.realtimeURL)
        XCTAssertEqual(FerryFeed.Source.patco.system, .lightRail)
        XCTAssertEqual(FerryFeed.Source.patco.boardingSeconds, 90)
        XCTAssertEqual(Set(feed.piers.map(\.name)), ["Lindenwold", "Broadway", "8th and Market", "15-16th and Locust"])
        // Westbound trips say "Philadelphia", as on the trains; eastbound ones end at Lindenwold
        let dayStart = Timetable.serviceDayStart(20261014, in: Timetable.timeZone)!
        let broadway = feed.arrivals(pierIDs: ["pat:8"], from: dayStart.addingTimeInterval(11 * 3600),
                                     to: dayStart.addingTimeInterval(14 * 3600), realtime: [], now: now)
        XCTAssertEqual(Set(broadway.map(\.direction.terminal)), ["Philadelphia", "Lindenwold"])
    }

    /// Philadelphia's shared stations: SEPTA's 8th-Market on the L1 and PATCO's 8th and Market 15 m apart, under SEPTA's name;
    /// PATCO's Broadway and NJ Transit's Walter Rand Transportation Center (River LINE) 19 m apart, under NJ Transit's
    func testPhiladelphiaStationsSharedWithPATCO() throws {
        func adding(_ rows: [String], to file: String, of files: [String: Data]) -> Data {
            Data((String(decoding: files[file]!, as: UTF8.self) + "\n" + rows.joined(separator: "\n") + "\n").utf8)
        }
        var njt = njtFiles
        njt["routes.txt"] = adding(["16,NJT,RIVLN,Riverline Light Rail,0,,00008B"], to: "routes.txt", of: njtFiles)
        njt["stops.txt"] = adding(["38307,30871,WALTER RAND TRANSPORTATION CTR,,39.943258,-75.120210,336",
                                   "38308,30872,TRENTON TRANSIT CENTER LIGHT RAIL,,40.218100,-74.754600,337"],
                                  to: "stops.txt", of: njtFiles)
        njt["trips.txt"] = adding(["16,1,9,TRENTON,0,4668,7"], to: "trips.txt", of: njtFiles)
        njt["stop_times.txt"] = adding(["9,12:10:00,12:10:00,38307,1,0,0,0", "9,13:20:00,13:20:00,38308,2,0,0,30"],
                                       to: "stop_times.txt", of: njtFiles)
        let feed = try FerryBuilder.build([.njTransitLightRail: njt, .septaMetro: septaMetroFiles, .patco: patcoFiles], now: now)
        let groups = feed.pierGroups()
        XCTAssertNotNil(groups["pat:11"])
        XCTAssertEqual(groups["pat:11"]?.group, groups["smt:2457"]?.group)
        XCTAssertEqual(groups["pat:11"]?.name, "8th-Market")
        XCTAssertNotNil(groups["pat:8"])
        XCTAssertEqual(groups["pat:8"]?.group, groups["njl:38307"]?.group)
        XCTAssertEqual(groups["pat:8"]?.name, feed.pier(id: "njl:38307")?.name)
        // Different stations stay apart: 15th St/City Hall (SEPTA) and 15-16th and Locust (PATCO) are 270 m apart with other names
        XCTAssertNotEqual(groups["smt:1392"]?.group ?? "smt", groups["pat:14"]?.group ?? "pat")
    }

    func testStopPositionNotesAreLeftOut() {
        XCTAssertEqual(FerryBuilder.withoutStopPositionNote("Girard Av & 40th St - FS"), "Girard Av & 40th St")
        XCTAssertEqual(FerryBuilder.withoutStopPositionNote("Market St & 15th St - MBNS 2"), "Market St & 15th St")
        XCTAssertEqual(FerryBuilder.withoutStopPositionNote("Bustleton Av & Cottman Av - 2 NS"), "Bustleton Av & Cottman Av")
        XCTAssertEqual(FerryBuilder.withoutStopPositionNote("Whitman Plaza - 1"), "Whitman Plaza")
        XCTAssertEqual(FerryBuilder.withoutStopPositionNote("Beaver St & Garden St - FS - Bristol Station"),
                       "Beaver St & Garden St - Bristol Station")
        XCTAssertEqual(FerryBuilder.withoutStopPositionNote("Frankford Transit Center"), "Frankford Transit Center")
        // Names with a dash of their own keep it
        XCTAssertEqual(FerryBuilder.withoutStopPositionNote("Wilkes-Barre"), "Wilkes-Barre")
        XCTAssertEqual(FerryBuilder.septaMetroStationName("Olney Transit Center - B2 & B3"), "Olney Transit Center")
        XCTAssertEqual(FerryBuilder.septaMetroStationName("Erie - B1"), "Erie")
        XCTAssertEqual(FerryBuilder.septaMetroStationName("8th-Market"), "8th-Market")
    }

    /// SEPTA's bus package (its buses and Metro, 26 MB) is downloaded only once a place in use is in the Philadelphia area
    func testSEPTAIsDownloadedOnlyForPlacesInItsArea() throws {
        PlacesInUse.reset()
        defer { PlacesInUse.reset() }
        let cityHall = Coordinate(latitude: 39.9524, longitude: -75.1636)
        let camden = Coordinate(latitude: 39.9259, longitude: -75.1196)
        let timesSquare = Coordinate(latitude: 40.7580, longitude: -73.9855)
        let princeton = Coordinate(latitude: 40.3487, longitude: -74.6593)
        let wilmington = Coordinate(latitude: 39.7391, longitude: -75.5398)
        XCTAssertTrue(DownloadArea.philadelphia.contains(cityHall))
        XCTAssertTrue(DownloadArea.philadelphia.contains(camden))
        XCTAssertFalse(DownloadArea.philadelphia.contains(timesSquare))
        XCTAssertFalse(DownloadArea.philadelphia.contains(princeton))
        XCTAssertFalse(DownloadArea.philadelphia.contains(wilmington))
        // Every stop of SEPTA's Metro and buses is inside (the real data's stops reach 39.80–40.34, -75.84 to -74.75)
        for corner in [Coordinate(latitude: 39.80, longitude: -75.84), Coordinate(latitude: 40.34, longitude: -74.75)] {
            XCTAssertTrue(DownloadArea.philadelphia.contains(corner))
        }
        let septaBus = try XCTUnwrap(RegionalBusFeed.feed(code: RegionalBusFeed.septaCode))
        XCTAssertEqual(septaBus.url, FerryFeed.septaBusURL)
        XCTAssertEqual(septaBus.downloadArea, .philadelphia)
        // Nothing in use there: not wanted (New York's operators and the ones in all areas are)
        PlacesInUse.set(.start, [timesSquare])
        XCTAssertFalse(FerryFeed.Source.septaMetro.isWanted)
        XCTAssertFalse(septaBus.isWanted)
        XCTAssertFalse(FerryFeed.Source.patco.isWanted)
        XCTAssertTrue(FerryFeed.Source.njTransitLightRail.isWanted)
        XCTAssertTrue(RegionalBusFeed.njTransit.isWanted)
        // A favorite or the starting point there, or the trip planner's place
        PlacesInUse.set(.favorites, [cityHall])
        XCTAssertTrue(FerryFeed.Source.septaMetro.isWanted)
        XCTAssertTrue(septaBus.isWanted)
        PlacesInUse.set(.favorites, [])
        PlacesInUse.set(.planner, [camden])
        XCTAssertTrue(PlacesInUse.any(in: .philadelphia))
        PlacesInUse.set(.planner, [])
        XCTAssertFalse(PlacesInUse.any(in: .philadelphia))
    }

    /// CTrail's Shore Line East comes in Amtrak's package: agency 1230, its one route called just "Commuter Rail", in Amtrak's light blue
    private var amtrakWithShoreLineEast: [String: Data] {
        var files = amtrakFiles
        func add(_ name: String, _ rows: String) { files[name] = (files[name] ?? Data()) + d("\n" + rows) }
        add("agency.txt", "1230,Shore Line East,http://www.amtrak.com,America/New_York,en")
        add("routes.txt", "42948,1230,,Commuter Rail,2,http://www.amtrak.com,CAE4F1,000000")
        add("stops.txt", """
        NLC,NLC,New London,,,41.354267,-72.093225
        OSB,OSB,Old Saybrook Amtrak Station,,,41.30039,-72.376818
        MDS,MDS,Madison,,,41.283577,-72.599444
        """)
        add("trips.txt", """
        42948,S1,9633,9633,0,,Stamford
        42948,S1,1600,1600,1,,New London
        42948,S1,1601,1601,1,,Old Saybrook
        """)
        add("stop_times.txt", """
        9633,6:18:00,6:18:00,OSB,1,0,0,1
        9633,6:33:00,6:33:00,MDS,2,0,0,1
        9633,7:00:00,7:00:00,STS,3,0,0,1
        9633,7:06:00,7:06:00,NHV,4,0,0,1
        9633,7:53:00,7:53:00,STM,5,0,0,1
        1600,12:10:00,12:10:00,NHV,1,0,0,1
        1600,12:40:00,12:40:00,MDS,2,0,0,1
        1600,13:00:00,13:00:00,OSB,3,0,0,1
        1600,13:30:00,13:30:00,NLC,4,0,0,1
        1601,17:10:00,17:10:00,NHV,1,0,0,1
        1601,17:40:00,17:40:00,MDS,2,0,0,1
        1601,18:00:00,18:00:00,OSB,3,0,0,1
        """)
        return files
    }

    /// Shore Line East stays a line of its own (badge, name, color) and stops at the same stations as Amtrak's trains
    func testShoreLineEastFromAmtrakPackage() throws {
        let feed = try FerryBuilder.build([.amtrakNY: amtrakWithShoreLineEast], now: now)
        // One more line; the other railroads and the buses in the package are still left out
        XCTAssertEqual(Set(feed.routes.map(\.id)), ["AMK-NER", "AMK-KEY", "AMK-SLE"])
        XCTAssertEqual(FerryFeed.shoreLineEastRoute, "AMK-SLE")
        XCTAssertTrue(FerryFeed.isShoreLineEast("AMK-SLE"))
        XCTAssertFalse(FerryFeed.isShoreLineEast("AMK-NER"))
        let sle = try XCTUnwrap(feed.route("AMK-SLE"))
        XCTAssertEqual(sle.name, "CTrail Shore Line East")
        XCTAssertEqual(FerryFeed.routeName("AMK-SLE"), "CTrail Shore Line East")
        XCTAssertEqual(FerryFeed.badge("AMK-SLE"), "SLE")
        XCTAssertTrue(FerryFeed.isRailRoute("AMK-SLE"))
        // Its own red, not the light blue the package gives it; white text on the badge can be read (4.5:1)
        XCTAssertEqual(sle.color, FerryFeed.shoreLineEast.color)
        XCTAssertEqual(sle.color, "D9383C")
        XCTAssertGreaterThanOrEqual(contrastWithWhite(sle.color), 4.5)
        // Amtrak's own lines are unchanged
        XCTAssertEqual(feed.route("AMK-NER")?.color, "00537E")
        XCTAssertEqual(feed.route("AMK-NER")?.name, "Amtrak Northeast Regional")
        // Its stations are Amtrak's: one New Haven, with both lines' trains
        XCTAssertTrue(Set(feed.piers.map(\.name)).isSuperset(of: ["New London", "Old Saybrook", "Madison", "New Haven", "New Haven State Street", "Stamford"]))
        XCTAssertEqual(feed.piers.filter { $0.name == "New Haven" }.count, 1)
        let newHaven = try XCTUnwrap(feed.piers.first { $0.name == "New Haven" }?.id)
        let arrivals = feed.arrivals(pierIDs: [newHaven], from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(6 * 3600),
                                     realtime: [], now: now)
        XCTAssertEqual(Set(arrivals.map(\.route)), ["AMK-NER", "AMK-SLE"])
        // Destinations as in the data
        XCTAssertEqual(Set(arrivals.filter { $0.route == "AMK-SLE" }.map(\.direction.terminal)), ["Stamford", "New London", "Old Saybrook"])
        // Directions as for Amtrak: east toward New London is "N", west toward New Haven and Stamford is "S"
        XCTAssertEqual(feed.trips.first { $0.id == "amk:1600" }?.direction, "N")
        XCTAssertEqual(feed.trips.first { $0.id == "amk:1601" }?.direction, "N")
        XCTAssertEqual(feed.trips.first { $0.id == "amk:9633" }?.direction, "S")
        XCTAssertEqual(feed.trips.first { $0.id == "amk:9633" }?.stops.count, 5)
        // The Amtrak trains are the same as without it
        let without = try FerryBuilder.build([.amtrakNY: amtrakFiles], now: now)
        XCTAssertEqual(feed.trips.filter { $0.route != "AMK-SLE" }, without.trips)
    }

    /// WCAG contrast ratio of white text on this background color ("D9383C")
    private func contrastWithWhite(_ hex: String) -> Double {
        let value = UInt32(hex, radix: 16) ?? 0
        func channel(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        return 1.05 / (luminance + 0.05)
    }

    // MARK: New Jersey ferries

    func testNewJerseyFerryKeepsNJOperators() throws {
        let route = FerryFeed.Route(id: "NYF-ER", name: "East River", color: "0077C8", realtime: true)
        let nyw = FerryFeed.Route(id: "NYW", name: "NY Waterway", color: "C8102E", realtime: true)
        let feed = FerryFeed(versions: ["nyf": "1", "nyw": "2"], routes: [route, nyw],
                             piers: [.init(id: "nyf:1", name: "Wall St", lat: 40.70, lon: -74.0),
                                     .init(id: "nyw:2", name: "Hoboken", lat: 40.73, lon: -74.03)],
                             trips: [], services: [:], shapes: [:])
        let nj = feed.filtered(for: .njFerry)
        XCTAssertEqual(nj.routes.map(\.id), ["NYW"])
        XCTAssertEqual(nj.piers.map(\.id), ["nyw:2"])
        XCTAssertEqual(feed.filtered(for: .ferry), feed)

        // No map route shapes in memory (keep only data that's used), everything else unchanged
        var withShapes = feed
        withShapes.shapes = ["NYW": [[[40.73, -74.03], [40.70, -74.0]]]]
        let slim = withShapes.withoutShapes()
        XCTAssertTrue(slim.shapes.isEmpty)
        XCTAssertEqual(slim, feed)
        XCTAssertEqual(withShapes.map().routes.map(\.route), ["NYW"])
        XCTAssertTrue(slim.map().routes.isEmpty)
    }

    // MARK: Real data (runs only on a Mac)

    /// CMT_NJT_ZIP points to rail_data.zip, CMT_AMTRAK_ZIP points to Amtrak's GTFS.zip.
    func testRealNewJerseyDataIfAvailable() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CMT_NJT_ZIP"] != nil || env["CMT_AMTRAK_ZIP"] != nil else { throw XCTSkip("CMT_NJT_ZIP / CMT_AMTRAK_ZIP not set") }
        #if canImport(Compression)
        var zips: [FerryFeed.Source: Data] = [:]
        if let p = env["CMT_NJT_ZIP"] {
            let zip = try Data(contentsOf: URL(fileURLWithPath: p))
            zips[.njTransitRail] = zip
            zips[.njTransitLightRail] = zip
        }
        if let p = env["CMT_AMTRAK_ZIP"] {
            let zip = try Data(contentsOf: URL(fileURLWithPath: p))
            zips[.amtrakNY] = zip
        }
        for system in [TransitSystem.lightRail, .train] {
            var files: [FerryFeed.Source: [String: Data]] = [:]
            var stopTimes: [FerryFeed.Source: FerryBuilder.RowSource] = [:]
            for source in FerryFeed.Source.cases(for: system) {
                guard let zip = zips[source] else { continue }
                files[source] = try ZipReader.read(zip, names: Array(FerryFeed.neededFiles.subtracting(["stop_times.txt"])))
                stopTimes[source] = { body in try ZipReader.forEachRow(zip, name: "stop_times.txt", body) }
            }
            guard !files.isEmpty else { continue }
            let clock = Date()
            let feed = try FerryBuilder.build(files, stopTimes: stopTimes, now: Date())
            let json = try feed.encoded()
            print("nj \(system.rawValue): built in \(String(format: "%.2f", Date().timeIntervalSince(clock))) s, \(feed.routes.count) routes \(feed.routes.map(\.id)), \(feed.piers.count) stations, \(feed.trips.count) trips, json \(json.count) bytes, map json \(try JSONEncoder().encode(feed.map()).count) bytes")
            print("nj \(system.rawValue): stations \(Set(feed.piers.map(\.name)).sorted().prefix(80))")
            print("nj \(system.rawValue): same station groups \(Set(feed.pierGroups().values.map(\.name)).sorted())")
            print("nj \(system.rawValue): ending soon \(feed.endingSources(from: Date()).map(\.rawValue).sorted())")
            XCTAssertTrue(feed.routes.allSatisfy { FerryFeed.badge($0.id).count <= 3 }, "Route badges are all short names: \(feed.routes.map(\.id))")
            XCTAssertFalse(feed.trips.isEmpty)
            for name in ["New York Penn Station", "Penn Station", "Newark Penn Station", "Hoboken", "Exchange Place"] {
                guard let id = feed.piers.first(where: { $0.name == name })?.id else { continue }
                let a = feed.arrivals(pierIDs: [id], from: Date(), to: Date().addingTimeInterval(2 * 3600), realtime: [], now: Date())
                print("nj \(system.rawValue): \(name) next 2 h: \(a.count) trains, e.g. \(a.prefix(4).map { "\($0.route) \($0.direction.code) \($0.direction.name)" })")
                print("nj \(system.rawValue): \(name) terminals \(feed.terminals(atPier: id).map { "\($0.route) \($0.direction) \($0.terminal)" })")
            }
        }
        #else
        throw XCTSkip("The Compression framework is only available on Apple platforms")
        #endif
    }

    func testMetroSubRegions() {
        func r(_ lat: Double, _ lon: Double) -> MetroSubRegion? { MetroSubRegion.of(Coordinate(latitude: lat, longitude: lon)) }
        XCTAssertEqual(r(40.7527, -73.9772), .newYorkCity)      // Grand Central
        XCTAssertEqual(r(40.5795, -74.1502), .newYorkCity)      // Staten Island
        XCTAssertEqual(r(40.7357, -74.0287), .northernNewJersey) // Hoboken
        XCTAssertEqual(r(40.7357, -74.1724), .northernNewJersey) // Newark
        XCTAssertEqual(r(40.7069, -73.6171), .longIsland)       // Hempstead
        XCTAssertEqual(r(41.0350, -71.9545), .longIsland)       // Montauk
        XCTAssertEqual(r(41.3083, -72.9279), .connecticut)      // New Haven
        XCTAssertEqual(r(41.0534, -73.5387), .connecticut)      // Stamford
        XCTAssertEqual(r(41.0340, -73.7629), .hudsonValley)     // White Plains
        XCTAssertEqual(r(41.7004, -73.9210), .hudsonValley)     // Poughkeepsie
        XCTAssertEqual(r(40.2206, -74.7597), .centralNewJersey) // Trenton
        XCTAssertEqual(r(39.9526, -75.1652), .philadelphia)     // Philadelphia
        XCTAssertEqual(r(39.3643, -74.4229), .southJersey)      // Atlantic City
        XCTAssertEqual(r(41.3220, -74.8020), .pikeCounty)       // Milford, PA
        XCTAssertEqual(r(40.6437, -74.0736), .newYorkCity)      // St. George (north shore of Staten Island)
        XCTAssertEqual(r(40.6687, -74.1143), .northernNewJersey) // Bayonne
        XCTAssertEqual(r(40.4966, -74.4455), .centralNewJersey) // New Brunswick
        XCTAssertEqual(r(40.6337, -74.4072), .northernNewJersey) // Plainfield
        // The Delaware River divides them: Pennsylvania's side is Philadelphia, never New Jersey; Delaware is its own region
        XCTAssertEqual(r(40.0429, -75.4836), .philadelphia)     // Paoli
        XCTAssertEqual(r(40.2454, -75.6496), .philadelphia)     // Pottstown
        XCTAssertEqual(r(40.3101, -75.1299), .philadelphia)     // Doylestown
        XCTAssertEqual(r(40.2415, -75.2838), .philadelphia)     // Lansdale
        XCTAssertEqual(r(40.1007, -74.8518), .philadelphia)     // Bristol, PA
        XCTAssertEqual(r(40.2115, -74.7882), .philadelphia)     // Morrisville, PA (across from Trenton)
        XCTAssertEqual(r(40.3643, -74.9513), .philadelphia)     // New Hope, PA
        XCTAssertEqual(r(40.6884, -75.2207), .northamptonCounty) // Easton, PA: the Lehigh Valley
        XCTAssertEqual(r(39.8187, -75.4180), .philadelphia)     // Marcus Hook, PA (just outside Delaware's arc)
        XCTAssertEqual(r(39.9259, -75.1196), .southJersey)      // Camden
        XCTAssertEqual(r(40.0712, -74.8649), .southJersey)      // Burlington, NJ (across from Bristol)
        XCTAssertEqual(r(39.7298, -75.4680), .southJersey)      // Penns Grove, NJ (across from Delaware)
        XCTAssertEqual(r(38.9351, -74.9060), .southJersey)      // Cape May
        XCTAssertEqual(r(40.3659, -74.9429), .centralNewJersey) // Lambertville, NJ (across from New Hope)
        // South Jersey by county line: Burlington County is South Jersey, Ocean and Mercer counties Central New Jersey
        XCTAssertEqual(r(39.9934, -74.7879), .southJersey)      // Mount Holly
        XCTAssertEqual(r(40.1460, -74.7110), .southJersey)      // Bordentown
        XCTAssertEqual(r(39.9718, -74.6838), .southJersey)      // Pemberton
        XCTAssertEqual(r(40.0260, -74.6250), .southJersey)      // Wrightstown
        XCTAssertEqual(r(39.6240, -74.4600), .southJersey)      // New Gretna (Bass River)
        XCTAssertEqual(r(39.3643, -74.4229), .southJersey)      // Atlantic City
        XCTAssertEqual(r(39.4864, -75.0260), .southJersey)      // Vineland
        XCTAssertEqual(r(40.0670, -74.5300), .centralNewJersey) // New Egypt (Ocean County)
        XCTAssertEqual(r(39.9537, -74.1979), .centralNewJersey) // Toms River
        XCTAssertEqual(r(39.6430, -74.1800), .centralNewJersey) // Ship Bottom, Long Beach Island
        XCTAssertEqual(r(39.6030, -74.3400), .centralNewJersey) // Tuckerton
        XCTAssertEqual(r(40.2070, -74.6800), .centralNewJersey) // Hamilton (Mercer County)
        XCTAssertEqual(r(39.7372, -75.5511), .delaware)         // Wilmington
        XCTAssertEqual(r(39.8007, -75.4596), .delaware)         // Claymont, DE (inside the arc)
        XCTAssertEqual(r(39.6697, -75.7535), .delaware)         // Newark DE
        XCTAssertEqual(r(39.4496, -75.7163), .delaware)         // Middletown DE
        XCTAssertEqual(r(39.1582, -75.5244), .delaware)         // Dover
        XCTAssertNil(r(38.7745, -75.1393))                      // Lewes: Sussex County, in no area, and more than 15 km from one's county
        XCTAssertNil(r(38.7209, -75.0760))                      // Rehoboth Beach, the same
        XCTAssertEqual(r(38.9329, -74.9179), .southJersey)      // Cape May, across the bay's mouth from Lewes
        XCTAssertEqual(r(41.3508, -71.9634), .connecticut)      // Mystic
        XCTAssertEqual(r(41.4735, -71.9614), .connecticut)      // Foxwoods
        XCTAssertEqual(r(40.3356, -75.9269), .berksCounty)      // Reading
        XCTAssertEqual(r(40.3337, -75.6374), .berksCounty)      // Boyertown
        XCTAssertEqual(r(40.5173, -75.7774), .berksCounty)      // Kutztown
        XCTAssertEqual(r(40.3051, -75.5838), .philadelphia)     // Gilbertsville, Montgomery County (just east of the line)
        XCTAssertEqual(r(40.2454, -75.6496), .philadelphia)     // Pottstown, Montgomery County
        XCTAssertEqual(r(40.2306, -75.6788), .philadelphia)     // North Coventry, Chester County (south of the Schuylkill)
        XCTAssertEqual(r(39.9590, -75.9194), .philadelphia)     // Parkesburg, Chester County
        XCTAssertEqual(r(39.7851, -75.9788), .philadelphia)     // Oxford, Chester County (north of the Mason-Dixon line)
        XCTAssertEqual(r(39.6068, -75.8333), .cecilCounty)      // Elkton, MD
        XCTAssertEqual(r(39.5604, -76.0716), .cecilCounty)      // Perryville, MD
        XCTAssertEqual(r(39.6837, -75.7497), .delaware)         // Newark DE, across the line from Elkton
        XCTAssertNil(r(42.6526, -73.7562))                      // Albany
        // The Bronx's northern line: Westchester above it, the Bronx below
        XCTAssertEqual(r(40.9312, -73.8988), .hudsonValley)     // Yonkers
        XCTAssertEqual(r(40.9126, -73.8371), .hudsonValley)     // Mount Vernon
        XCTAssertEqual(r(40.9115, -73.7824), .hudsonValley)     // New Rochelle
        XCTAssertEqual(r(40.8960, -73.8070), .hudsonValley)     // Pelham Manor
        XCTAssertEqual(r(40.9490, -73.7330), .hudsonValley)     // Mamaroneck
        XCTAssertEqual(r(40.9026, -73.9050), .newYorkCity)      // Riverdale
        XCTAssertEqual(r(40.9038, -73.9143), .newYorkCity)      // Riverdale station
        XCTAssertEqual(r(40.9031, -73.8507), .newYorkCity)      // Wakefield-241 St
        XCTAssertEqual(r(40.8740, -73.8300), .newYorkCity)      // Co-op City
        XCTAssertEqual(r(40.8650, -73.8050), .newYorkCity)      // Pelham Bay Park
        XCTAssertEqual(r(40.8478, -73.7865), .newYorkCity)      // City Island
        // The Hudson bends east: the New Jersey shore facing Manhattan is New Jersey, Manhattan's west side stays New York City
        XCTAssertEqual(r(40.8504, -73.9701), .northernNewJersey) // Fort Lee
        XCTAssertEqual(r(40.8270, -73.9760), .northernNewJersey) // Edgewater
        XCTAssertEqual(r(40.8210, -73.9880), .northernNewJersey) // Cliffside Park
        XCTAssertEqual(r(40.8040, -74.0120), .northernNewJersey) // North Bergen
        XCTAssertEqual(r(40.7920, -74.0040), .northernNewJersey) // Guttenberg
        XCTAssertEqual(r(40.7870, -74.0090), .northernNewJersey) // West New York
        XCTAssertEqual(r(40.7760, -74.0170), .northernNewJersey) // Weehawken (Port Imperial)
        XCTAssertEqual(r(40.7466, -74.0085), .newYorkCity)      // Chelsea Piers
        XCTAssertEqual(r(40.7590, -74.0040), .newYorkCity)      // Pier 76
        XCTAssertEqual(r(40.7810, -73.9880), .newYorkCity)      // Riverside Park at 72nd St
        XCTAssertEqual(r(40.8500, -73.9470), .newYorkCity)      // Little Red Lighthouse
        XCTAssertEqual(r(40.8720, -73.9260), .newYorkCity)      // Inwood Hill Park
    }

    /// One representative place per region, each falling in its region (to check the region boundaries).
    func testRepresentativePlacesCoverEveryRegion() {
        let places: [(Double, Double, MetroSubRegion)] = [
            (40.7557, -73.9871, .newYorkCity), (40.7527, -73.9772, .newYorkCity), (40.6437, -74.0736, .newYorkCity),
            (40.7676, -73.5283, .longIsland),
            (41.0330, -73.7752, .hudsonValley),
            (40.7359, -74.0291, .northernNewJersey),
            (40.4966, -74.4455, .centralNewJersey),
            (39.9557, -75.1820, .philadelphia),
            (39.9259, -75.1196, .southJersey),
            (39.7372, -75.5511, .delaware),
            (41.0466, -73.5419, .connecticut),
            (41.3223, -74.8024, .pikeCounty),
            (40.3356, -75.9269, .berksCounty),
            (39.6068, -75.8333, .cecilCounty),
            (40.6023, -75.4714, .lehighCounty),       // Allentown
            (40.6259, -75.3705, .northamptonCounty),  // Bethlehem
            (40.8676, -75.7402, .carbonCounty),       // Jim Thorpe
            (40.9868, -75.1946, .monroeCounty),       // Stroudsburg
            (40.6937, -75.1902, .warrenCounty),       // Phillipsburg
            (42.3554, -71.0605, .boston),
            (42.5195, -70.8967, .northShore),         // Salem
            (41.9584, -70.6673, .southShore),         // Plymouth
            (42.2626, -71.8023, .centralMassachusetts), // Worcester
            (41.6362, -70.9342, .bristolCounty),      // New Bedford
            (41.6532, -70.2827, .capeCod),            // Hyannis
            (41.3890, -70.5134, .dukesCounty),        // Edgartown, Martha's Vineyard
            (41.2835, -70.0995, .nantucketCounty),    // Nantucket
            (41.8240, -71.4128, .rhodeIsland),        // Providence
            (42.9956, -71.4548, .newHampshire),       // Manchester
            (43.0881, -70.7364, .yorkCounty),         // Kittery
            (41.7658, -72.6734, .hartford),
            (41.9151, -71.9087, .northeasternConnecticut), // Putnam
            (41.8007, -73.1212, .northwestHills),     // Torrington
            (42.1015, -72.5898, .pioneerValley),      // Springfield
            (42.4501, -73.2454, .berkshires),         // Pittsfield
        ]
        XCTAssertEqual(places.count, 35)
        for (lat, lon, region) in places {
            XCTAssertEqual(MetroSubRegion.of(Coordinate(latitude: lat, longitude: lon)), region, "\(lat), \(lon)")
        }
        XCTAssertEqual(Set(places.map(\.2)), Set(MetroSubRegion.allCases))
    }

    /// Settings' data sources by metro area: every operator is in at least one area, by where its stations are
    func testEveryOperatorHasAMetroArea() {
        for source in FerryFeed.Source.allCases {
            XCTAssertFalse(MetroArea.areas(of: source).isEmpty, source.name)
        }
        for feed in RegionalBusFeed.all {
            XCTAssertFalse(MetroArea.areas(ofBus: feed).isEmpty, feed.name)
            // A company downloaded only around Philadelphia, Reading, Chester and Cecil Counties, South Jersey or Cape May is listed
            // in the Philadelphia area, one downloaded only in the Lehigh Valley in the Lehigh Valley, one only around Hartford in
            // Greater Hartford, one only in the Pioneer Valley, Franklin County or the Berkshires in Western Massachusetts, one
            // only around its stops in New Jersey and New York (Academy's reach Philadelphia's area too) in the New York area, one
            // only in Greater Boston or around it (one box per operator) in Greater Boston
            if let area = feed.downloadArea {
                let philadelphia: [DownloadArea] = [.philadelphia, .reading, .chesterAndCecil, .southJersey, .capeMay]
                let hartford: [DownloadArea] = [.northeasternConnecticut, .windham, .northwestHills]
                let westernMassachusetts: [DownloadArea] = [.pioneerValley, .franklinCounty, .berkshires]
                let newYork: [DownloadArea] = [.shortLine, .suburbanTransit, .rocklandCoaches, .communityCoach, .newarkAirportExpress,
                                               .orangeWestchester, .lakeland, .hunterdon, .academy, .somerset, .sussex]
                let metro: MetroArea = area == .lehighValley ? .lehighValley : philadelphia.contains(area) ? .philadelphia
                    : hartford.contains(area) ? .greaterHartford : westernMassachusetts.contains(area) ? .westernMassachusetts
                    : newYork.contains(area) ? .newYork : .greaterBoston
                XCTAssertTrue(MetroArea.areas(ofBus: feed).contains(metro), feed.name)
            }
        }
        // The Philadelphia area's only ferry is the Cape May–Lewes Ferry (its Cape May terminal); MARC's only station kept is Perryville
        XCTAssertEqual(FerryFeed.Source.allCases.filter { $0.system.mode == .ferry && MetroArea.areas(of: $0).contains(.philadelphia) },
                       [.capeMayLewes])
        XCTAssertEqual(MetroArea.areas(of: .capeMayLewes), [.philadelphia])
        XCTAssertEqual(MetroArea.areas(of: .marc), [.philadelphia])
        // In both: Trenton (Central New Jersey, so the New York area) is on SEPTA's and NJ Transit's trains and on SEPTA's buses
        XCTAssertEqual(MetroArea.areas(of: .septaRail), [.newYork, .philadelphia])
        // Amtrak stops in five (New Haven, Philadelphia, Boston, Hartford, Springfield); the Hartford Line and CTtransit in New
        // Haven's and Hartford's areas, the Hartford Line in Springfield too
        XCTAssertEqual(MetroArea.areas(of: .amtrakNY), [.newYork, .philadelphia, .greaterBoston, .greaterHartford, .westernMassachusetts])
        XCTAssertEqual(MetroArea.areas(of: .hartfordLine), [.newYork, .greaterHartford, .westernMassachusetts])
        // The MBTA's four parts are Greater Boston's alone
        for source in [FerryFeed.Source.mbtaSubway, .mbtaRail, .mbtaFerry] { XCTAssertEqual(MetroArea.areas(of: source), [.greaterBoston]) }
        // NJ Transit's buses also run in Phillipsburg (Warren County) and to Easton, its trains to Hackettstown (Warren County)
        XCTAssertEqual(MetroArea.areas(ofBus: RegionalBusFeed.njTransit), [.newYork, .philadelphia, .lehighValley])
        XCTAssertEqual(MetroArea.areas(of: .njTransitRail), [.newYork, .philadelphia, .lehighValley])
        XCTAssertEqual(MetroArea.areas(of: .patco), [.philadelphia])
        XCTAssertEqual(MetroArea.areas(of: .path), [.newYork])
        let code = { (code: String) in RegionalBusFeed.all.first { $0.code == code }! }
        for c in ["POTT", "TMACC", "UMR", "BARTA", "CECIL", "PHLASH", "BURL", "GLOU", "ATLC", "CUMB", "SJTA"] where RegionalBusFeed.all.contains(where: { $0.code == c }) {
            XCTAssertEqual(MetroArea.areas(ofBus: code(c)), [.philadelphia], c)
        }
        XCTAssertEqual(MetroArea.areas(ofBus: code("BXL")), [.newYork])
        for c in ["LANTA", "PONY", "WARR"] { XCTAssertEqual(MetroArea.areas(ofBus: code(c)), [.lehighValley], c) }
        // Trans-Bridge's coaches stop in all three: Port Authority and Newark Airport, Doylestown, Allentown
        XCTAssertEqual(MetroArea.areas(ofBus: code("TBL")), [.newYork, .philadelphia, .lehighValley])
        XCTAssertEqual(MetroArea.areas(ofBus: code("MBTA")), [.greaterBoston])
        // The 17 bus operators around Boston: Greater Boston's alone (COAST's stops in York County, Maine, are Greater Boston's too),
        // but for MART, whose buses reach Athol and Orange (Franklin County, in Western Massachusetts)
        for c in Self.greaterBostonBuses {
            XCTAssertEqual(MetroArea.areas(ofBus: code(c)), c == "MART" ? [.greaterBoston, .westernMassachusetts] : [.greaterBoston], c)
        }
        // Greater Hartford's and Western Massachusetts' six: each in the areas its stops are in. PVTA's reach Worcester and Enfield,
        // FRTA's Athol, NECTD's and WRTD's Lisbon and Norwich in southeastern Connecticut (the New York area's Connecticut)
        XCTAssertEqual(MetroArea.areas(ofBus: code("CTT")), [.newYork, .greaterHartford])
        XCTAssertEqual(MetroArea.areas(ofBus: code("PVTA")), [.greaterBoston, .greaterHartford, .westernMassachusetts])
        XCTAssertEqual(MetroArea.areas(ofBus: code("FRTA")), [.greaterBoston, .westernMassachusetts])
        XCTAssertEqual(MetroArea.areas(ofBus: code("BRTA")), [.westernMassachusetts])
        XCTAssertEqual(MetroArea.areas(ofBus: code("NECTD")), [.newYork, .greaterHartford])
        XCTAssertEqual(MetroArea.areas(ofBus: code("WRTD")), [.newYork, .greaterHartford])
        XCTAssertEqual(MetroArea.areas(ofBus: code("NWCTD")), [.greaterHartford])
        // A place's area
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 40.7557, longitude: -73.9871)), .newYork)       // Times Sq
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 40.2185, longitude: -74.7539)), .newYork)       // Trenton
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 39.9556, longitude: -75.1820)), .philadelphia)  // 30th St
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 40.3356, longitude: -75.9269)), .philadelphia)  // Reading
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 39.6068, longitude: -75.8333)), .philadelphia)  // Elkton
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 40.3726, longitude: -75.4807)), .philadelphia)  // Red Hill, Montgomery County
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 40.6023, longitude: -75.4714)), .lehighValley)  // Allentown
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 42.3523, longitude: -71.0552)), .greaterBoston) // South Station
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 41.7658, longitude: -72.6734)), .greaterHartford)      // Hartford
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 41.8007, longitude: -73.1212)), .greaterHartford)      // Torrington
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 42.1015, longitude: -72.5898)), .westernMassachusetts) // Springfield
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 42.4501, longitude: -73.2454)), .westernMassachusetts) // Pittsfield
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 41.2977, longitude: -72.9267)), .newYork)              // New Haven
        XCTAssertNil(MetroArea.of(Coordinate(latitude: 42.6526, longitude: -73.7562)))                    // Albany
        let philadelphia: [MetroSubRegion] = [.philadelphia, .delaware, .southJersey, .berksCounty, .cecilCounty]
        let lehighValley: [MetroSubRegion] = [.lehighCounty, .northamptonCounty, .carbonCounty, .monroeCounty, .warrenCounty]
        let boston: [MetroSubRegion] = [.boston, .northShore, .southShore, .centralMassachusetts, .bristolCounty, .capeCod, .dukesCounty,
                                        .nantucketCounty, .rhodeIsland, .newHampshire, .yorkCounty]
        let hartford: [MetroSubRegion] = [.hartford, .northeasternConnecticut, .northwestHills]
        let westernMassachusetts: [MetroSubRegion] = [.pioneerValley, .berkshires]
        for region in MetroSubRegion.allCases {
            XCTAssertEqual(region.metroArea, philadelphia.contains(region) ? .philadelphia : lehighValley.contains(region) ? .lehighValley
                           : boston.contains(region) ? .greaterBoston : hartford.contains(region) ? .greaterHartford
                           : westernMassachusetts.contains(region) ? .westernMassachusetts : .newYork, region.rawValue)
        }
    }

    /// The new Pennsylvania and Maryland bus companies are downloaded only where they run
    func testNewBusCompaniesDownloadOnlyInTheirArea() {
        let feed = { (code: String) in RegionalBusFeed.all.first { $0.code == code } }
        let at = { (lat: Double, lon: Double) in Coordinate(latitude: lat, longitude: lon) }
        XCTAssertEqual(feed("POTT")?.downloadArea, .philadelphia)
        XCTAssertEqual(feed("UMR")?.downloadArea, .philadelphia)
        XCTAssertEqual(feed("BARTA")?.downloadArea, .reading)
        XCTAssertEqual(feed("TMACC")?.downloadArea, .chesterAndCecil)
        XCTAssertEqual(feed("CECIL")?.downloadArea, .chesterAndCecil)
        XCTAssertTrue(DownloadArea.philadelphia.contains(at(40.2454, -75.6496)))    // Pottstown
        XCTAssertTrue(DownloadArea.philadelphia.contains(at(40.0893, -75.3963)))    // King of Prussia
        XCTAssertTrue(DownloadArea.reading.contains(at(40.3356, -75.9269)))         // Reading
        XCTAssertTrue(DownloadArea.reading.contains(at(40.5173, -75.7774)))         // Kutztown
        XCTAssertTrue(DownloadArea.chesterAndCecil.contains(at(39.9607, -75.6055))) // West Chester
        XCTAssertTrue(DownloadArea.chesterAndCecil.contains(at(39.6068, -75.8333))) // Elkton
        XCTAssertTrue(DownloadArea.chesterAndCecil.contains(at(39.5604, -76.0716))) // Perryville
        for a in [DownloadArea.reading, .chesterAndCecil] {
            XCTAssertFalse(a.contains(at(40.7557, -73.9871)), a.rawValue)          // Times Sq
            XCTAssertFalse(a.contains(at(39.9526, -75.1652)), a.rawValue)          // City Hall
        }
        XCTAssertFalse(DownloadArea.reading.contains(at(39.9607, -75.6055)))        // West Chester
        // South Jersey's county shuttles and SJTA: every stop the data has, from its four corners (checked on a Mac, 2026-11-08)
        for code in ["BURL", "GLOU", "ATLC", "CUMB", "SJTA"] { XCTAssertEqual(feed(code)?.downloadArea, .southJersey, code) }
        for (name, lat, lon) in [("Amazon Distribution Center, BurLINK's north", 40.1096, -74.7989), ("Beverly", 40.0611, -74.9153),
                                 ("Spring Lake, Pemberton", 39.9404, -74.5450), ("Pennsauken Park and Ride", 39.9931, -75.0393),
                                 ("Beckett Rd, Logan Township", 39.7589, -75.3557), ("Atlantic City Bus Terminal", 39.3598, -74.4349),
                                 ("Atlantic Ave at Tennessee Ave", 39.3621, -74.4285), ("Bridgeton Villas", 39.4216, -75.2473),
                                 ("Bridgeton Industrial Park", 39.4114, -75.2126), ("Wheat Rd, Buena", 39.5120, -74.9490)] {
            XCTAssertTrue(DownloadArea.southJersey.contains(at(lat, lon)), name)
            XCTAssertTrue(ServiceArea.contains(at(lat, lon)), name)
            XCTAssertEqual(MetroSubRegion.of(at(lat, lon)), .southJersey, name)
        }
        XCTAssertFalse(DownloadArea.southJersey.contains(at(40.7557, -73.9871)))   // Times Sq
        XCTAssertFalse(DownloadArea.southJersey.contains(at(40.2185, -74.7539)))   // Trenton
        XCTAssertFalse(DownloadArea.southJersey.contains(at(38.9351, -74.9060)))   // Cape May (no stop there)
    }

    static let greaterBostonBuses = ["RIPTA", "WRTA", "LRTA", "GATRA", "SRTA", "BAT", "CCRTA", "MART", "MEVA", "CATA", "MWRTA", "LOGAN",
                                     "MANCH", "NTS", "COAST", "VTA", "NRTA"]

    /// The bus operators around Boston are downloaded only where they run, each in its own box: their outermost stops (from each
    /// one's data, read 2026-11-12) are in it, and the middle of Boston is in none of them but Massport's (the Logan Express from
    /// Back Bay)
    func testGreaterBostonBusCompaniesDownloadOnlyInTheirArea() {
        let feed = { (code: String) in RegionalBusFeed.all.first { $0.code == code } }
        let at = { (lat: Double, lon: Double) in Coordinate(latitude: lat, longitude: lon) }
        XCTAssertEqual(Self.greaterBostonBuses.count, 17)
        let stops: [(String, DownloadArea, [(String, Double, Double)])] = [
            ("RIPTA", .rhodeIsland, [("Bellingham Stop & Shop", 42.0188, -71.4982), ("Sand Hill Cove", 41.3740, -71.4931),
                                     ("Fall River", 41.6983, -71.1543), ("Westerly station", 41.3811, -71.8298)]),
            ("WRTA", .worcester, [("West Boylston", 42.3555, -71.7829), ("Webster", 42.0275, -71.8503),
                                  ("Tri-County Medical Center", 42.1261, -71.6415), ("Brookfield", 42.2148, -72.1007)]),
            ("LRTA", .lowell, [("Middlesex St", 42.6999, -71.4361), ("Burlington Mall", 42.4805, -71.2126),
                               ("Wilmington", 42.5469, -71.1744), ("IBM, Westford", 42.5496, -71.4680)]),
            ("GATRA", .attleboroAndTaunton, [("Medway", 42.1460, -71.4065), ("New Bedford", 41.6358, -70.9279),
                                             ("Plymouth", 41.8896, -70.5399)]),
            ("SRTA", .fallRiverAndNewBedford, [("Four Winds", 41.7626, -71.1093), ("UMass SMAST", 41.5968, -70.9073),
                                               ("Wareham", 41.7581, -70.6634), ("Swansea", 41.7550, -71.2199)]),
            ("BAT", .brockton, [("Ashmont", 42.2844, -71.0641), ("Fall River", 41.6983, -71.1544), ("Hanover", 42.1235, -70.9075),
                                ("Stoughton", 42.1395, -71.1489)]),
            ("CCRTA", .capeCod, [("Race Point Beach", 42.0794, -70.2195), ("Woods Hole", 41.5230, -70.6698),
                                 ("Orleans", 41.6827, -69.9619)]),
            ("MART", .montachusett, [("Winchendon", 42.6840, -72.0463), ("Worcester Union Station", 42.2615, -71.7948),
                                     ("Bedford", 42.5049, -71.2731), ("Orange", 42.5918, -72.3152)]),
            ("MEVA", .merrimackValley, [("Amesbury", 42.8594, -70.9273), ("Lowell", 42.6360, -71.3140),
                                        ("Salisbury Beach", 42.8423, -70.8197)]),
            ("CATA", .capeAnn, [("Halibut Point", 42.6866, -70.6318), ("Northshore Mall", 42.5395, -70.9438),
                                ("Rockport", 42.6479, -70.5986)]),
            ("MWRTA", .metroWest, [("South Acton", 42.4605, -71.4578), ("Forge Park", 42.0892, -71.4394),
                                   ("Woodland", 42.3332, -71.2431), ("Solomon Pond Mall", 42.3551, -71.6125)]),
            ("LOGAN", .loganExpress, [("Danvers", 42.5549, -70.9414), ("Braintree", 42.2174, -71.0369),
                                      ("Framingham", 42.3011, -71.3978), ("Back Bay, Dartmouth St", 42.3481, -71.0774)]),
            ("MANCH", .manchester, [("Concord", 43.2125, -71.5344), ("Nashua", 42.7584, -71.4656), ("Salem, NH", 42.7779, -71.2078)]),
            ("NTS", .nashua, [("Amherst", 42.8106, -71.5796), ("Pheasant Lane Mall", 42.7012, -71.4360)]),
            ("COAST", .seacoast, [("Rochester", 43.3942, -71.0656), ("Seabrook road, Hampton", 43.0228, -70.7952),
                                  ("Portsmouth Naval Shipyard, Kittery", 43.0859, -70.7423), ("Rochester, west", 43.3899, -71.0850)]),
            // The islands' buses (from their data read 2026-11-12), each only on its own island
            ("VTA", .marthasVineyard, [("Gay Head Lighthouse, Aquinnah", 41.3466, -70.8365), ("West Chop Lighthouse", 41.4805, -70.5999),
                                       ("Chilmark Overlook", 41.3235, -70.7706), ("Mattakesett, Edgartown", 41.3532, -70.5105)]),
            ("NRTA", .nantucket, [("End of Madaket Road", 41.2715, -70.2003), ("Sankaty Road, Sconset", 41.2653, -69.9638),
                                  ("Surfside Beach", 41.2440, -70.0948), ("Quidnet Road", 41.3009, -70.0018)]),
        ]
        XCTAssertEqual(stops.map(\.0), Self.greaterBostonBuses)
        for (code, area, places) in stops {
            XCTAssertEqual(feed(code)?.downloadArea, area, code)
            for (name, lat, lon) in places { XCTAssertTrue(area.contains(at(lat, lon)), "\(code): \(name)") }
        }
        // Downtown Boston: only Massport's box (and the MBTA's, all of Greater Boston)
        let southStation = at(42.3523, -71.0552)
        XCTAssertEqual(stops.map(\.1).filter { $0.contains(southStation) }, [.loganExpress])
        XCTAssertTrue(DownloadArea.greaterBoston.contains(southStation))
        // Each box with a corner of Greater Boston's: none reaches New York's, Philadelphia's or the Lehigh Valley's
        for (code, area, _) in stops {
            XCTAssertFalse(area.contains(at(40.7557, -73.9871)), code)   // Times Sq
            XCTAssertTrue(DownloadArea.greaterBoston.box.lat.lowerBound <= area.box.lat.lowerBound
                          && area.box.lat.upperBound <= DownloadArea.greaterBoston.box.lat.upperBound
                          && DownloadArea.greaterBoston.box.lon.lowerBound <= area.box.lon.lowerBound
                          && area.box.lon.upperBound <= DownloadArea.greaterBoston.box.lon.upperBound, code)
        }
        // COAST's stops in Maine are in the service area now, in York County's region
        let shipyard = at(43.0859, -70.7423)
        XCTAssertTrue(ServiceArea.contains(shipyard))
        XCTAssertEqual(MetroSubRegion.of(shipyard), .yorkCounty)
        // The islands' buses: in the service area, in their islands' regions, and each island's box leaves out the other island
        XCTAssertEqual(MetroSubRegion.of(at(41.3466, -70.8365)), .dukesCounty)
        XCTAssertEqual(MetroSubRegion.of(at(41.2715, -70.2003)), .nantucketCounty)
        XCTAssertFalse(DownloadArea.marthasVineyard.contains(at(41.2847, -70.0927)))   // Nantucket's Straight Wharf
        XCTAssertFalse(DownloadArea.nantucket.contains(at(41.4588, -70.5544)))         // Oak Bluffs' pier
    }

    /// Greater Hartford's and Western Massachusetts' bus operators are downloaded only where they run, each in its own box: their
    /// outermost stops (from each one's data, read 2026-11-12; WRTD's, whose data couldn't be read then, by the ends of its
    /// published routes) are in it and in the service area, in one of the operator's metro areas
    func testHartfordAndWesternMassachusettsBusCompaniesDownloadOnlyInTheirArea() {
        let feed = { (code: String) in RegionalBusFeed.all.first { $0.code == code } }
        let at = { (lat: Double, lon: Double) in Coordinate(latitude: lat, longitude: lon) }
        let stops: [(String, DownloadArea, [(String, Double, Double, MetroSubRegion)])] = [
            ("PVTA", .pioneerValley, [("South Deerfield Center", 42.4770, -72.6075, .pioneerValley),
                                      ("MassMutual, Enfield", 42.0181, -72.5849, .hartford),
                                      ("Union Station Garage, Worcester", 42.2602, -71.7952, .centralMassachusetts),
                                      ("Westfield State University", 42.1307, -72.7967, .pioneerValley)]),
            ("FRTA", .franklinCounty, [("Federated Church of Charlemont", 42.6281, -72.8697, .pioneerValley),
                                       ("Academy of Music, Northampton", 42.3177, -72.6334, .pioneerValley),
                                       ("Hannaford Supermarket Plaza, Athol", 42.5829, -72.2627, .centralMassachusetts),
                                       ("Charlemont Center", 42.6275, -72.8769, .pioneerValley)]),
            ("BRTA", .berkshires, [("Proprietors Fields, Williamstown", 42.7171, -73.1971, .berkshires),
                                   ("Claire Teague Senior Center, Great Barrington", 42.1742, -73.3624, .berkshires),
                                   ("JWO Transit Center, Greenfield", 42.5854, -72.6006, .pioneerValley),
                                   ("Simon's Rock", 42.2062, -73.3809, .berkshires)]),
            ("NECTD", .northeasternConnecticut, [("Thompson Public Library", 41.9848, -71.8996, .northeasternConnecticut),
                                                 ("Lisbon Landing", 41.5854, -71.9898, .connecticut),
                                                 ("Matulaitis Nursing Home, Putnam", 41.9284, -71.8564, .northeasternConnecticut)]),
            ("WRTD", .windham, [("Willimantic", 41.7107, -72.2081, .connecticut), ("Storrs", 41.8084, -72.2495, .hartford),
                                ("Norwich", 41.5243, -72.0759, .connecticut),
                                ("Danielson", 41.8023, -71.8859, .northeasternConnecticut)]),
            ("NWCTD", .northwestHills, [("Geer Village, Canaan", 42.0168, -73.3311, .northwestHills),
                                        ("Bantam Post Office", 41.7269, -73.2364, .northwestHills),
                                        ("Barkhamsted Park and Ride", 41.9091, -73.0463, .northwestHills),
                                        ("BD Factory, Canaan", 42.0120, -73.3352, .northwestHills)]),
        ]
        XCTAssertEqual(stops.map(\.0), RegionalBusFeed.builtIn.suffix(6).map(\.code))
        for (code, area, places) in stops {
            XCTAssertEqual(feed(code)?.downloadArea, area, code)
            let areas = feed(code).map { MetroArea.areas(ofBus: $0) } ?? []
            for (name, lat, lon, region) in places {
                XCTAssertTrue(area.contains(at(lat, lon)), "\(code): \(name)")
                XCTAssertTrue(ServiceArea.contains(at(lat, lon)), "\(code): \(name)")
                XCTAssertEqual(MetroSubRegion.of(at(lat, lon)), region, "\(code): \(name)")
                XCTAssertTrue(areas.contains(region.metroArea), "\(code): \(name)")
            }
            // Every area the operator is listed in has one of these stops, so none is listed where it doesn't run
            XCTAssertEqual(Set(places.map { $0.3.metroArea }), Set(areas), code)
            // None reaches New York City, Boston or New Haven
            for (name, lat, lon) in [("Times Sq", 40.7557, -73.9871), ("South Station", 42.3523, -71.0552), ("New Haven", 41.2977, -72.9267)] {
                XCTAssertFalse(area.contains(at(lat, lon)), "\(code): \(name)")
            }
        }
        // The middle of Hartford is in none of the six boxes (CTtransit, the Hartford Line and Amtrak are downloaded for everyone
        // there); Springfield's Union Station only in PVTA's, Pittsfield's only in BRTA's, Greenfield's in FRTA's and BRTA's
        // (the Link413 buses)
        let boxes = { (lat: Double, lon: Double) in stops.map(\.1).filter { $0.contains(at(lat, lon)) } }
        XCTAssertEqual(boxes(41.7689, -72.6815), [])
        XCTAssertEqual(boxes(42.1061, -72.5933), [.pioneerValley])
        XCTAssertEqual(boxes(42.4519, -73.2538), [.berkshires])
        XCTAssertEqual(boxes(42.5854, -72.6006), [.franklinCounty, .berkshires])
        XCTAssertEqual(boxes(41.8007, -73.1212), [.northwestHills])                          // Torrington
        XCTAssertEqual(boxes(41.8023, -71.8859), [.northeasternConnecticut, .windham])       // Danielson
    }
}

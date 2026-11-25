import XCTest
@testable import TransitCore

/// Ferries: tested with small samples in the same format as the real data (real data is downloaded on a Mac, see testRealFeedsIfAvailable).
final class FerryTests: XCTestCase {

    /// Large packages one at a time: never two inside at once, each turn handed to one waiting, and free again at the end
    func testLargePackagesOneAtATime() async {
        let gate = OneAtATime()
        let log = TurnLog()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<4 {
                group.addTask {
                    await gate.enter()
                    await log.add("in \(i)")
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    await log.add("out \(i)")
                    await gate.leave()
                }
            }
        }
        let events = await log.events
        XCTAssertEqual(events.count, 8)
        for k in stride(from: 0, to: events.count, by: 2) {
            XCTAssertTrue(events[k].hasPrefix("in "), "\(events)")
            XCTAssertEqual(events[k + 1], "out " + events[k].dropFirst(3), "\(events)")
        }
        // Free again once everyone left: the next one gets in at once
        await gate.enter()
        await gate.leave()
    }

    private func d(_ s: String) -> Data { Data(s.utf8) }

    /// NYC Ferry sample: East River in both directions + a shuttle bus (to be filtered out); shapes has columns in lon, lat order.
    private var nycFiles: [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color
            ER,1,ER,East River,4,00839C
            RES,1,RES,Rockaway Shuttle,3,000000
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            87,Wall St/Pier 11,40.70300,-74.00700
            20,Dumbo/Fulton Ferry,40.70400,-73.99400
            88,Hunters Point South &amp; LIC,40.74200,-73.95900
            99,Shuttle Stop,40.58000,-73.83000
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id,shape_id
            ER,1,t1,(E R A),0,s0
            ER,1,t2,Wall St.,1,s1
            RES,1,b1,Shuttle,0,
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            t1,08:00:00,08:00:00,87,1
            t1,08:10:00,08:10:00,20,2
            t1,08:30:00,08:30:00,88,3
            t2,09:00:00,09:00:00,88,1
            t2,09:20:00,09:20:00,20,2
            t2,09:30:00,09:30:00,87,3
            b1,08:00:00,08:00:00,99,1
            b1,08:20:00,08:20:00,87,2
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            1,1,1,1,1,1,0,0,20261003,20271231
            """),
            "calendar_dates.txt": d("service_id,date,exception_type\n"),
            "shapes.txt": d("""
            shape_id,shape_pt_lon,shape_pt_lat,shape_pt_sequence
            s0,-74.00700,40.70300,1
            s0,-73.99400,40.70400,2
            s0,-73.95900,40.74200,3
            s1,-73.95900,40.74200,1
            s1,-73.99400,40.70400,2
            s1,-74.00700,40.70300,3
            """),
            "feed_info.txt": d("feed_publisher_name,feed_version\nNYC Ferry,2026-10-03\n"),
        ]
    }

    /// Staten Island Ferry sample: like the real data it has a BOM, commas inside stop_desc (quoted), and real coordinates;
    /// no directions or terminals; one trip starts and ends at St. George (to be filtered out).
    private var sifFiles: [String: Data] {
        [
            "routes.txt": d("\u{FEFF}" + """
            route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color,route_sort_order,continuous_pickup,continuous_drop_off
            SIF,NYC DOT,,Staten Island Ferry,The Ferry operates between the St. George Ferry Terminal on Staten Island and the Whitehall Terminal in Lower Manhattan. The trip is free and take about 25 minutes. The ferry does not carry cars.,4,,FF8330,000000,,,
            """),
            "stops.txt": d("\u{FEFF}" + """
            stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,zone_id,stop_url,location_type,parent_station,stop_timezone,wheelchair_boarding
            stgeorge,,St. George Ferry Terminal,"Located at 1 Bay Street, Staten Island, at the intersection of Bay Street and Richmond Terrace.",40.644169,-74.072201,,,0,,,1
            whitehall,,Whitehall Ferry Terminal,"Located at Peter Minuit Plaza, at the intersection of Whitehall and Water Streets in Manhattan.",40.70136,-74.012666,,,0,,,1
            """),
            "trips.txt": d("\u{FEFF}route_id,service_id,trip_id,shape_id\nSIF,weekday,w1,whitehall\nSIF,weekday,s1,stgeorge\nSIF,weekday,loop,stgeorge\nSIF,holiday,h1,whitehall\n"),
            "stop_times.txt": d("\u{FEFF}trip_id,arrival_time,departure_time,stop_id,stop_sequence\nw1,08:00:00,08:00:00,whitehall,1\nw1,08:25:00,08:25:00,stgeorge,2\ns1,08:30:00,08:30:00,stgeorge,1\ns1,08:55:00,08:55:00,whitehall,2\nloop,09:00:00,09:00:00,stgeorge,1\nloop,09:30:00,09:30:00,stgeorge,2\nh1,10:00:00,10:00:00,whitehall,1\nh1,10:25:00,10:25:00,stgeorge,2\n"),
            "calendar.txt": d("\u{FEFF}service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nweekday,1,1,1,1,1,0,0,20260101,20280130\nholiday,0,0,0,0,0,0,0,20260101,20280130\n"),
            "calendar_dates.txt": d("\u{FEFF}service_id,date,exception_type\nweekday,20261126,2\nholiday,20261126,1\n"),
        ]
    }

    /// NY Waterway sample: header, piers and calendar match the real 2026-10 data (14 routes in the feed, 5 kept here).
    /// - Pier 11 has exactly the same coordinates as Wall St/Pier 11 in the NYC Ferry sample (same in the real data)
    /// - The Edgewater → Port Imperial → Midtown boat only drops off at Port Imperial (pickup_type 1)
    /// - The South Amboy boat goes via Brookfield Place to Pier 11; Haverstraw–Ossining is too far from New York (to be filtered out)
    /// - calendar.txt plus a Christmas suspension in calendar_dates.txt
    private var nywFiles: [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color,route_url
            "11",20190,"11","Port Imperial - Midtown/W39th",4,4FBFA5,FFFFFF,"https://nywaterway.connexionz.net/RTT/Public/Schedule.aspx?RouteNo=11"
            "15",20190,"15","Hoboken/NJT - Pier 11/Wall St",4,7D004E,FFFFFF,"https://nywaterway.connexionz.net/RTT/Public/Schedule.aspx?RouteNo=15"
            "21",20190,"21","Edgewater - Midtown/W39th",4,F9AA8F,000000,"https://nywaterway.connexionz.net/RTT/Public/Schedule.aspx?RouteNo=21"
            "50",20190,"50","Haverstraw - Ossining",4,204285,FFFFFF,"https://nywaterway.connexionz.net/RTT/Public/Schedule.aspx?RouteNo=50"
            "69",20190,"69","South Amboy - Midtown/W39th",4,,,"https://nywaterway.connexionz.net/RTT/Public/Schedule.aspx?RouteNo=69"
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_lat,stop_lon,stop_url,location_type,platform_code,stop_desc,stop_timezone,wheelchair_boarding
            4,"BPT","Brookfield Place Terminal",40.715029,-74.017775,"https://nywaterway.connexionz.net/RTT/Public/Transit.aspx?page=text&amp;plt=4",,,,,
            5,"EGWATER","Edgewater Ferry Landing",40.827934,-73.969722,"https://nywaterway.connexionz.net/RTT/Public/Transit.aspx?page=text&amp;plt=5",,,,,
            8,"HAVSTRW","Haverstraw",41.192803,-73.957989,"https://nywaterway.connexionz.net/RTT/Public/Transit.aspx?page=text&amp;plt=8",,,,,
            10,"HOB. SO.","Hoboken / NJ Transit Terminal",40.735127,-74.026492,"https://nywaterway.connexionz.net/RTT/Public/Transit.aspx?page=text&amp;plt=10",,,,,
            11,"PORT IMP","Port Imperial / Weehawken",40.776397,-74.010043,"https://nywaterway.connexionz.net/RTT/Public/Transit.aspx?page=text&amp;plt=11",,,,,
            14,"MIDTOWN","Midtown / W. 39th St.",40.760595,-74.003862,"https://nywaterway.connexionz.net/RTT/Public/Transit.aspx?page=text&amp;plt=14",,,,,
            16,"OSSINING","Ossining",41.157038,-73.871415,"https://nywaterway.connexionz.net/RTT/Public/Transit.aspx?page=text&amp;plt=16",,,,,
            18,"PIER 11","Pier 11 / Wall St.",40.70300,-74.00700,"https://nywaterway.connexionz.net/RTT/Public/Transit.aspx?page=text&amp;plt=18",,,,,
            30,"SA","South Amboy",40.489683,-74.274482,"https://nywaterway.connexionz.net/RTT/Public/Transit.aspx?page=text&amp;plt=30",,,,,
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id
            11,6,3636,Midtown/W39th,,0,1,1101
            11,6,3637,Port Imperial,,1,1,1102
            15,6,5136,Pier 11/Wall St,,0,2,1501
            15,6,5137,Hoboken/NJT,,1,2,1502
            21,6,7463,Midtown/W39th,,0,3,2101
            21,6,7464,Edgewater,,1,3,2102
            50,6,7698,Ossining,,0,4,5001
            69,6,7784,Pier 11/Wall St,,0,5,6901
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,stop_headsign,pickup_type,drop_off_type,timepoint
            3636,06:00:00,06:00:00,11,1,,0,0,1
            3636,06:10:00,06:10:00,14,2,,0,0,1
            3637,06:20:00,06:20:00,14,1,,0,0,1
            3637,06:30:00,06:30:00,11,2,,0,0,1
            5136,06:20:00,06:20:00,10,1,,0,0,1
            5136,06:35:00,06:35:00,18,2,,0,0,1
            5137,06:45:00,06:45:00,18,1,,0,0,1
            5137,07:00:00,07:00:00,10,2,,0,0,1
            7463,06:05:00,06:05:00,5,1,,0,0,1
            7463,06:20:00,06:20:00,11,2,,1,0,1
            7463,06:25:00,06:25:00,14,3,,0,0,1
            7464,06:40:00,06:40:00,14,1,,0,0,1
            7464,07:00:00,07:00:00,5,2,,0,0,1
            7698,05:46:00,05:46:00,8,1,,0,0,1
            7698,06:00:00,06:00:00,16,2,,0,0,1
            7784,05:35:00,05:35:00,30,1,,0,0,1
            7784,06:25:00,06:25:00,4,2,Pier 11/Wall St,0,0,1
            7784,06:35:00,06:35:00,18,3,Pier 11/Wall St,0,0,1
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            5,0,0,0,0,1,0,0,20261012,20271231
            6,1,1,1,1,1,0,0,20261012,20271231
            8,0,0,0,0,0,1,1,20261012,20271231
            """),
            "calendar_dates.txt": d("service_id,date,exception_type\n5,20261225,2\n6,20261225,2\n"),
            "shapes.txt": d("""
            shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence
            1101,40.776397,-74.010043,1
            1101,40.768000,-74.006000,2
            1101,40.760595,-74.003862,3
            1102,40.760595,-74.003862,1
            1102,40.768000,-74.006000,2
            1102,40.776397,-74.010043,3
            1501,40.735127,-74.026492,1
            1501,40.703000,-74.007000,2
            1502,40.703000,-74.007000,1
            1502,40.735127,-74.026492,2
            2101,40.827934,-73.969722,1
            2101,40.776397,-74.010043,2
            2101,40.760595,-74.003862,3
            2102,40.760595,-74.003862,1
            2102,40.827934,-73.969722,2
            5001,41.192803,-73.957989,1
            5001,41.157038,-73.871415,2
            6901,40.489683,-74.274482,1
            6901,40.715029,-74.017775,2
            6901,40.703000,-74.007000,3
            """),
            "feed_info.txt": d("""
            feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date,feed_version
            "Connexionz Ltd","https://www.connexionz.com",en,20261012,20271231,20261013
            """),
        ]
    }

    /// Seastreak sample: header and piers match the real 2026-10 data.
    /// - No calendar.txt (only calendar_dates.txt), no direction_id, stop_sequence may start at 3,
    ///   no feed_version in feed_info, commas and "&amp;#038;" in route_desc
    /// - Battery Maritime Building Slip 5 is about 100 m from Whitehall (a separate building next door, must not merge);
    ///   Brookfield Place is 16 m from NY Waterway's Brookfield Place Terminal (same pier)
    /// - The Martha's Vineyard boat is too far from New York (to be filtered out); the Sandy Hook boat runs only in summer
    private var sstFiles: [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color
            270,20226,Seastreak,"Martha’s Vineyard / New Bedford","Between New Bedford &amp;#038; Martha’s Vineyard, MA",4,https://seastreak.com/ferry-routes-and-schedules/between-new-bedford-marthas-vineyard-ma/,013067,FFFFFF
            267,20226,Seastreak,"Sandy Hook Beach / New York City","Between New York City &amp;#038; Sandy Hook Beach, NJ",4,https://seastreak.com/ferry-routes-and-schedules/between-new-york-city-sandy-hook-beach-nj/,013067,FFFFFF
            211,20226,Seastreak,"New York City / New Jersey","Between New Jersey &amp;#038; New York City",4,https://seastreak.com/ferry-routes-and-schedules/between-new-jersey-and-new-york-city/,013067,FFFFFF
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_desc,stop_lat,stop_lon,stop_url,location_type,wheelchair_boarding
            9825,"Brookfield Place, NY","Battery Park City Vessey Street on the West Side of Manhattan",40.715161,-74.017695,https://seastreak.com/what-to-know/port-locations-directions-parking/brookfield-place-ny/,0,0
            186,"New Bedford, MA","49 State Pier",41.635526,-70.919669,https://seastreak.com/what-to-know/port-locations-directions-parking/new-bedford-ma/,0,1
            184,"Oak Bluffs, Martha’s Vineyard, MA","Steamship Authority Terminal at One Sea View Avenue",41.458596,-70.55447,https://seastreak.com/what-to-know/port-locations-directions-parking/marthas-vineyard-ma/,0,1
            179,"Sandy Hook Beach, NJ","35 Hartshorne Drive",40.464613,-74.007661,https://seastreak.com/what-to-know/port-locations-directions-parking/sandy-hook-beach-nj/,0,1
            176,"Highlands, NJ","326 Shore Drive",40.409395,-73.996238,https://seastreak.com/what-to-know/port-locations-directions-parking/highlands-nj/,0,1
            175,"Atlantic Highlands, NJ","Bottom of First Avenue at the Atlantic Highlands Municipal Marina",40.419668,-74.034889,https://seastreak.com/what-to-know/port-locations-directions-parking/atlantic-highlands-nj/,0,1
            170,"Battery Maritime Building Slip 5","10 South Street",40.700894,-74.011612,https://seastreak.com/what-to-know/port-locations-directions-parking/battery-maritime-building/,0,1
            168,"East 35th St., NYC","East 35th St. and the FDR on the East Side of Manhattan",40.743873,-73.97069,https://seastreak.com/what-to-know/port-locations-directions-parking/e-35th-st-nyc/,0,1
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,shape_id,trip_headsign,bikes_allowed
            211,13182,13182_0_0,4101,New York City,1
            211,13183,13183_0_0,4102,Atlantic Highlands,1
            211,13190,13190_0_0,4103,Brookfield Place,1
            267,13230,13230_0_0,4201,Sandy Hook Beach,1
            270,12247,12247_0_0,4301,Martha’s Vineyard,1
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,timepoint,pickup_type,drop_off_type
            13182_0_0,05:45:00,05:45:00,176,3,,0,1
            13182_0_0,06:25:00,06:25:00,170,4,,0,0
            13182_0_0,06:45:00,06:45:00,168,5,,0,0
            13183_0_0,17:00:00,17:00:00,168,1,,0,1
            13183_0_0,17:20:00,17:20:00,170,2,,0,0
            13183_0_0,18:05:00,18:05:00,175,3,,1,0
            13190_0_0,07:00:00,07:00:00,175,1,,0,1
            13190_0_0,07:45:00,07:45:00,9825,2,,1,0
            13230_0_0,10:30:00,10:30:00,168,1,,0,1
            13230_0_0,11:00:00,11:00:00,170,2,,0,0
            13230_0_0,11:45:00,11:45:00,179,3,,1,0
            12247_0_0,08:20:00,08:20:00,186,1,,0,1
            12247_0_0,09:15:00,09:15:00,184,2,,1,0
            """),
            "calendar_dates.txt": d("""
            service_id,date,exception_type
            13182,20261014,1
            13182,20261015,1
            13183,20261014,1
            13183,20261015,1
            13190,20261014,1
            13230,20260704,1
            12247,20260801,1
            """),
            "shapes.txt": d("""
            shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence
            4101,40.409395,-73.996238,1
            4101,40.700894,-74.011612,2
            4101,40.743873,-73.97069,3
            4102,40.743873,-73.97069,1
            4102,40.700894,-74.011612,2
            4102,40.419668,-74.034889,3
            4103,40.419668,-74.034889,1
            4103,40.715161,-74.017695,2
            4201,40.743873,-73.97069,1
            4201,40.700894,-74.011612,2
            4201,40.464613,-74.007661,3
            4301,41.635526,-70.919669,1
            4301,41.458596,-70.55447,2
            """),
            "feed_info.txt": d("""
            feed_start_date,feed_end_date,feed_publisher_name,feed_publisher_url,feed_lang
            20200920,20261230,Seastreak,https://seastreak.com,EN
            """),
        ]
    }

    /// Statue of Liberty ferry (National Park Service, NPS) sample: header, pier coordinates, route names and calendar match real data downloaded on a Mac.
    /// - The main routes are loops (Battery Park → Liberty Island → Ellis Island → Battery Park; the New Jersey one starts at Liberty State Park)
    /// - direction_id is always 1, no trip_headsign; the destination is only in stop_headsign (with the typo "Libery")
    /// - pickup_type is always empty; this season runs 2026-09-08 to 2026-10-12, with no data after
    private var solFiles: [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color,route_sort_order
            NY,NPS,,Battery Park Full Loop,,4,https://www.cityexperiences.com/new-york/city-cruises/statue/new-york-reserve/,,,
            LIBP,NPS,,Liberty Island - Battery Park Evening Return ONLY,,4,,,,
            NJ,NPS,,Liberty State Park Loop,,4,https://www.cityexperiences.com/new-york/city-cruises/statue/new-jersey-reserve/,,,
            LSPClr,NPS,,Liberty Island Liberty State Park Evening Return ONLY,,4,,,,
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,zone_id,stop_url,location_type,parent_station,stop_timezone,wheelchair_boarding
            EI,,Ellis Island,,40.698939,-74.040506,,,,,,1
            LI,,Liberty Island,,40.689834,-74.047706,,,,,,1
            BP,,Battery Park,,40.701617,-74.016198,,,,,,1
            LSP,,Liberty State Park,,40.707675,-74.033775,,,,,,1
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id,wheelchair_accessible,bikes_allowed
            NY,fall,Battery Park Full Loop Fall_T01,,1,,NYloop,1,
            NY,weekend,Battery Park Full Loop Weekend_T01,,1,,NYloop,1,
            NJ,fall,Liberty State Park Loop Fall_T01,,1,,NJloop,1,
            LIBP,fall,Liberty Island - Battery Park Evening Return ONLY_T01,,1,,,1,
            LSPClr,fall,Liberty State Park Evening Return ONLY_T01,,1,,,1,
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,stop_headsign,pickup_type,drop_off_type,continuous_pickup,continuous_drop_off,shape_dist_traveled,timepoint
            Battery Park Full Loop Fall_T01,09:00:00,09:00:00,BP,1,Liberty Island,,,,,0,1
            Battery Park Full Loop Fall_T01,09:20:00,09:20:00,LI,2,Ellis Island,,,,,1.9,1
            Battery Park Full Loop Fall_T01,10:20:00,10:20:00,EI,3,Battery Park,,,,,2.5,1
            Battery Park Full Loop Fall_T01,10:40:00,10:40:00,BP,4,,,,,,4.0,1
            Battery Park Full Loop Weekend_T01,09:30:00,09:30:00,BP,1,Liberty Island,,,,,0,1
            Battery Park Full Loop Weekend_T01,09:50:00,09:50:00,LI,2,Ellis Island,,,,,1.9,1
            Battery Park Full Loop Weekend_T01,10:50:00,10:50:00,EI,3,Battery Park,,,,,2.5,1
            Battery Park Full Loop Weekend_T01,11:10:00,11:10:00,BP,4,,,,,,4.0,1
            Liberty State Park Loop Fall_T01,08:30:00,08:30:00,LSP,1,Ellis Island,,,,,0,1
            Liberty State Park Loop Fall_T01,08:50:00,08:50:00,EI,2,Liberty Island,,,,,1.814,1
            Liberty State Park Loop Fall_T01,09:10:00,09:10:00,LI,3,Liberty State Park,,,,,4.178,1
            Liberty State Park Loop Fall_T01,09:25:00,09:25:00,LSP,4,,,,,,7.66,1
            Liberty Island - Battery Park Evening Return ONLY_T01,17:00:00,17:00:00,LI,1,Battery Park,,,,,0,1
            Liberty Island - Battery Park Evening Return ONLY_T01,17:15:00,17:15:00,BP,2,,,,,,2.0,1
            Liberty State Park Evening Return ONLY_T01,16:50:00,16:50:00,LI,1,Ellis Island,,,,,0,1
            Liberty State Park Evening Return ONLY_T01,17:10:00,17:10:00,EI,2,Libery State Park,,,,,2.379,1
            Liberty State Park Evening Return ONLY_T01,17:25:00,17:25:00,LSP,3,,,,,,4.215,1
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            fall,1,1,1,1,1,1,1,20260908,20261012
            weekend,0,0,0,0,0,1,1,20260908,20261012
            weekday,1,1,1,1,1,0,0,20260908,20261012
            """),
            "calendar_dates.txt": d("service_id,date,exception_type\n"),
            "shapes.txt": d("""
            shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence,shape_dist_traveled
            NYloop,40.701617,-74.016198,1,0
            NYloop,40.689834,-74.047706,2,1.9
            NYloop,40.698939,-74.040506,3,2.5
            NYloop,40.701617,-74.016198,4,4.0
            NJloop,40.707675,-74.033775,1,0
            NJloop,40.698939,-74.040506,2,1.814
            NJloop,40.689834,-74.047706,3,4.178
            NJloop,40.707675,-74.033775,4,7.66
            """),
            "feed_info.txt": d("""
            feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date,feed_version,feed_contact_email,feed_contact_url
            NPS STLI,https://www.nps.gov/subjects/developer/gtfs.htm,en,20260908,20261012,20260908,,
            """),
        ]
    }

    private func feed() throws -> FerryFeed { try FerryBuilder.build(nyc: nycFiles, sif: sifFiles) }

    private func allFour() throws -> FerryFeed {
        try FerryBuilder.build(nyc: nycFiles, sif: sifFiles, nyw: nywFiles, sst: sstFiles)
    }

    /// A given time on a given day in New York.
    private func ny(_ day: Int, _ h: Int, _ m: Int) -> Date {
        Timetable.serviceDayStart(day, in: Timetable.timeZone)!.addingTimeInterval(TimeInterval(h * 3600 + m * 60))
    }

    /// The stored copy remembers which way of reading the packages built it, so an update that reads them differently builds it again once
    func testStoredDataRemembersHowItWasBuilt() throws {
        XCTAssertEqual(FerryFeed.contentVersion(for: .train), 7)
        for system in [TransitSystem.ferry, .path, .lightRail] {
            XCTAssertEqual(FerryFeed.contentVersion(for: system), 1, system.rawValue)
        }
        for system in TransitSystem.allCases where ![.train, .ferry, .path, .lightRail].contains(system) {
            XCTAssertEqual(FerryFeed.contentVersion(for: system), 0, system.rawValue)
        }
        // A copy stored before the mark existed has none: built the old way for trains, ferries, PATH and light rail, current for the rest
        let oldJSON = String(decoding: try FerryFeed.empty.encoded(), as: UTF8.self)
        XCTAssertFalse(oldJSON.contains("builtWith"))
        let old = try FerryFeed.decode(Data(oldJSON.utf8))
        XCTAssertNil(old.builtWith)
        XCTAssertTrue(old.isOutdated(for: .train))
        XCTAssertTrue(old.isOutdated(for: .ferry))
        XCTAssertTrue(old.isOutdated(for: .path))
        XCTAssertTrue(old.isOutdated(for: .lightRail))
        XCTAssertFalse(old.isOutdated(for: .njBus))
        // The mark survives storing and reading back, and dropping the map shapes
        var marked = FerryFeed.empty
        marked.builtWith = 7
        marked.shapes = ["AMK-NER": [[[40.7506, -73.9935], [40.7347, -74.1643]]]]
        let back = try FerryFeed.decode(marked.encoded())
        XCTAssertEqual(back.builtWith, 7)
        XCTAssertEqual(back.shapes.count, 1)
        XCTAssertEqual(back.withoutShapes().builtWith, 7)
        XCTAssertFalse(back.isOutdated(for: .train))
        // Built with a reading before this version's: read again once
        marked.builtWith = 6
        XCTAssertTrue(marked.isOutdated(for: .train))
        XCTAssertFalse(marked.isOutdated(for: .ferry))
    }

    /// The new mark is written only once every operator in the copy was read by this version; operators kept from an older copy keep its mark
    func testMarkedOnlyOnceEveryOperatorIsReadAgain() {
        func feed(_ sources: [FerryFeed.Source], builtWith: Int? = nil) -> FerryFeed {
            var f = FerryFeed(versions: Dictionary(uniqueKeysWithValues: sources.map { ($0.rawValue, "20261101") }),
                              routes: [], piers: [], trips: [], services: [:], shapes: [:])
            f.builtWith = builtWith
            return f
        }
        let trains: [FerryFeed.Source] = [.lirr, .metroNorth, .njTransitRail, .amtrakNY, .hartfordLine]
        let old = feed(trains)
        XCTAssertEqual(old.sources, Set(trains))
        // Every operator read again: marked as current
        var all = feed(trains)
        all.markBuilt(for: .train, read: Set(trains), older: old)
        XCTAssertEqual(all.builtWith, 7)
        XCTAssertFalse(all.isOutdated(for: .train))
        // One failed and was kept from the old copy: still the old mark, so it's read again later (the others aren't needed again)
        var partial = feed(trains)
        partial.markBuilt(for: .train, read: Set(trains).subtracting([.hartfordLine]), older: old)
        XCTAssertNil(partial.builtWith)
        XCTAssertTrue(partial.isOutdated(for: .train))
        // Later in the same run the failed one gets through: every operator has now been read again
        partial.markBuilt(for: .train, read: Set(trains), older: partial)
        XCTAssertEqual(partial.builtWith, 7)
        // A copy already current stays current when only some operators are downloaded (e.g. the monthly check of one operator)
        var monthly = feed(trains)
        monthly.markBuilt(for: .train, read: [.lirr], older: feed(trains, builtWith: 7))
        XCTAssertEqual(monthly.builtWith, 7)
        // A copy from the previous way of reading keeps its mark when only partly read again, so the rest is read again later
        var previous = feed(trains)
        previous.markBuilt(for: .train, read: [.lirr], older: feed(trains, builtWith: 6))
        XCTAssertEqual(previous.builtWith, 6)
        XCTAssertTrue(previous.isOutdated(for: .train))
        // First download with one operator failing: nothing is kept from an older copy, so the copy is current (the missing one is downloaded anyway)
        var first = feed(Array(trains.dropLast()))
        first.markBuilt(for: .train, read: Set(trains.dropLast()), older: nil)
        XCTAssertEqual(first.builtWith, 7)
        // A copy from a newer version that reads differently keeps a mark no higher than this version's when only partly read again
        var newer = feed(trains)
        newer.markBuilt(for: .train, read: [.lirr], older: feed(trains, builtWith: 8))
        XCTAssertEqual(newer.builtWith, 7)
        // Ferries have their own mark: a copy without one is current once every operator in it was read again
        let ferries: [FerryFeed.Source] = [.nycFerry, .statenIsland]
        var ferry = feed(ferries)
        XCTAssertTrue(ferry.isOutdated(for: .ferry))
        ferry.markBuilt(for: .ferry, read: [.nycFerry], older: feed(ferries))
        XCTAssertNil(ferry.builtWith)
        XCTAssertTrue(ferry.isOutdated(for: .ferry))
        ferry.markBuilt(for: .ferry, read: Set(ferries), older: feed(ferries))
        XCTAssertEqual(ferry.builtWith, 1)
        XCTAssertFalse(ferry.isOutdated(for: .ferry))
        // Systems whose reading never changed write no mark, so their files stay as they were
        var bus = feed([.njTransitBus])
        bus.markBuilt(for: .njBus, read: [.njTransitBus], older: feed([.njTransitBus]))
        XCTAssertNil(bus.builtWith)
        XCTAssertFalse(bus.isOutdated(for: .njBus))
    }

    func testBuildFiltersShuttlesLoopsAndDecodesNames() throws {
        let f = try feed()
        XCTAssertEqual(f.routes.map(\.id).sorted(), ["NYF-ER", "SIF"])
        XCTAssertEqual(f.route("SIF")?.realtime, false)
        XCTAssertEqual(f.route("NYF-ER")?.realtime, true)
        XCTAssertEqual(f.route("NYF-ER")?.color, "00839C")
        XCTAssertEqual(f.pier(id: "nyf:88")?.name, "Hunters Point South & LIC")
        XCTAssertEqual(f.pier(id: "sif:stgeorge")?.name, "St. George Ferry Terminal")
        XCTAssertFalse(f.trips.contains { $0.id == "nyf:b1" })
        XCTAssertFalse(f.trips.contains { $0.id == "sif:loop" })
        XCTAssertEqual(f.trips.first { $0.id == "sif:w1" }?.direction, "N")
        XCTAssertEqual(f.trips.first { $0.id == "sif:s1" }?.direction, "S")
        XCTAssertEqual(f.trips.first { $0.id == "nyf:t2" }?.direction, "S")
        XCTAssertEqual(f.versions["nyf"], "2026-10-03")
        XCTAssertEqual(f.sources, [.nycFerry, .statenIsland])
        // shapes columns are lon, lat: read by column name; latitude should be around 40
        XCTAssertEqual(f.shapes["NYF-ER"]?.count, 1, "The same line in the opposite direction is drawn only once")
        XCTAssertEqual(f.shapes["NYF-ER"]?.first?.first?.first ?? 0, 40.703, accuracy: 0.001)
        XCTAssertNotNil(f.shapes["SIF"], "Without shapes.txt, connect the piers with lines")
        // Same after encoding and reading back
        XCTAssertEqual(try FerryFeed.decode(f.encoded()), f)
    }

    func testBadgesAndRouteCheck() {
        XCTAssertTrue(FerryFeed.isFerryRoute("NYF-ER"))
        XCTAssertTrue(FerryFeed.isFerryRoute("SIF"))
        XCTAssertFalse(FerryFeed.isFerryRoute("SI"))
        XCTAssertFalse(FerryFeed.isFerryRoute("Q53+"))
        XCTAssertEqual(FerryFeed.badge("NYF-SB"), "SB")
        XCTAssertEqual(FerryFeed.badge("SIF"), "SI")
    }

    func testScheduledArrivalsSkipTripsEndingHere() throws {
        let f = try feed()
        let day = 20261014   // Wednesday
        let list = f.arrivals(pierIDs: ["nyf:87", "nyf:20"], from: ny(day, 7, 0), to: ny(day, 12, 0), now: ny(day, 7, 0))
        // 87 is t1's origin (boarding allowed) and t2's terminal (not shown); 20 has both directions
        XCTAssertEqual(list.map(\.id), ["nyf:t1|\(day)|nyf:87", "nyf:t1|\(day)|nyf:20", "nyf:t2|\(day)|nyf:20"])
        XCTAssertTrue(list.allSatisfy { $0.source == .scheduled })
        XCTAssertEqual(list[0].direction.terminal, "Hunters Point South & LIC")
        XCTAssertEqual(list[2].direction.terminal, "Wall St/Pier 11")
        XCTAssertEqual(list[2].direction.code, "S")
        XCTAssertEqual(list[1].arrivalTime, ny(day, 8, 10))
        // No weekday trips on Saturday
        XCTAssertTrue(f.arrivals(pierIDs: ["nyf:87"], from: ny(20261017, 7, 0), to: ny(20261017, 12, 0)).isEmpty)
    }

    /// What a direction with nothing in the arrival window says comes next: the first departure after it per pier, line and
    /// direction, from the timetable, less than a day ahead (so its clock time alone says when)
    func testNextDeparturesAfterTheWindow() throws {
        let f = try feed()
        let day = 20261014   // Wednesday
        let next = f.nextDepartures(pierIDs: ["nyf:87", "nyf:20"], after: ny(day, 7, 0), now: ny(day, 5, 0))
        XCTAssertEqual(Set(next.map(\.id)), ["nyf:t1|\(day)|nyf:87", "nyf:t1|\(day)|nyf:20", "nyf:t2|\(day)|nyf:20"])
        XCTAssertTrue(next.allSatisfy { $0.source == .scheduled })
        // Staten Island Ferry: the 8:00 before it leaves; after it, Thanksgiving's 10:00 the next morning (22 hours on)
        XCTAssertEqual(f.nextDepartures(pierIDs: ["sif:whitehall"], after: ny(20261125, 6, 0)).map(\.arrivalTime), [ny(20261125, 8, 0)])
        XCTAssertEqual(f.nextDepartures(pierIDs: ["sif:whitehall"], after: ny(20261125, 12, 0)).map(\.arrivalTime), [ny(20261126, 10, 0)])
        // More than 23 hours ahead isn't said: the clock time alone would read as today's
        XCTAssertTrue(f.nextDepartures(pierIDs: ["sif:whitehall"], after: ny(20261125, 9, 0)).isEmpty)
        XCTAssertTrue(f.nextDepartures(pierIDs: [], after: ny(day, 7, 0)).isEmpty)
    }

    func testStatenIslandHolidaySwap() throws {
        let f = try feed()
        let normal = f.arrivals(pierIDs: ["sif:whitehall"], from: ny(20261125, 7, 0), to: ny(20261125, 12, 0))
        XCTAssertEqual(normal.map(\.route), ["SIF"])
        XCTAssertEqual(normal.first?.arrivalTime, ny(20261125, 8, 0))
        XCTAssertEqual(normal.first?.direction.terminal, "St. George Ferry Terminal")
        // Thanksgiving: weekday trips replaced by holiday trips
        let holiday = f.arrivals(pierIDs: ["sif:whitehall"], from: ny(20261126, 7, 0), to: ny(20261126, 12, 0))
        XCTAssertEqual(holiday.first?.arrivalTime, ny(20261126, 10, 0))
        XCTAssertEqual(holiday.count, 1)
    }

    func testRealtimeDelayIsCarriedForwardAndPassedStopsHidden() throws {
        let f = try feed()
        let day = 20261014
        let now = ny(day, 8, 3)
        // t1 has already left 87 (8:02, 2 minutes late); next stop 20 expected at 8:13 (3 minutes late)
        let rt = FerryRealtime(timestamp: now, trips: [
            "t1": .init(stopTimes: [.init(stopID: "87", time: ny(day, 8, 2)), .init(stopID: "20", time: ny(day, 8, 13))]),
        ], fetchedAt: now)
        let list = f.arrivals(pierIDs: ["nyf:87", "nyf:20", "nyf:88"], from: now, to: ny(day, 12, 0), realtime: rt, now: now)
        let t1 = list.filter { $0.id.hasPrefix("nyf:t1|") }
        XCTAssertEqual(t1.map(\.stationID), ["nyf:20"], "87 has already been served; 88 is the terminal")
        XCTAssertEqual(t1.first?.arrivalTime, ny(day, 8, 13))
        XCTAssertEqual(t1.first?.source, .realtime)
        // t2 has no realtime data: use the timetable, marked as scheduled
        let t2 = list.first { $0.id.hasPrefix("nyf:t2|") && $0.stationID == "nyf:88" }
        XCTAssertEqual(t2?.source, .scheduled)
        XCTAssertEqual(t2?.arrivalTime, ny(day, 9, 0))
    }

    func testCanceledTripIsHidden() throws {
        let f = try feed()
        let day = 20261014
        let now = ny(day, 7, 0)
        let rt = FerryRealtime(timestamp: now, trips: ["t1": .init(stopTimes: [], canceled: true)], fetchedAt: now)
        let list = f.arrivals(pierIDs: ["nyf:87"], from: now, to: ny(day, 12, 0), realtime: rt, now: now)
        XCTAssertTrue(list.isEmpty)
    }

    func testNearbyPiersAndTerminals() throws {
        let f = try feed()
        let near = f.stations(near: Coordinate(latitude: 40.7035, longitude: -74.0), radiusMeters: 1500)
        XCTAssertEqual(near.map(\.id), ["nyf:20", "nyf:87", "sif:whitehall"])
        XCTAssertFalse(near.contains { $0.id == "nyf:99" }, "A stop with only a shuttle bus isn't a pier")
        XCTAssertEqual(f.routesByPier()["nyf:20"], ["NYF-ER"])
        let t = f.terminals(atPier: "nyf:20")
        XCTAssertEqual(t.map(\.terminal), ["Hunters Point South & LIC", "Wall St/Pier 11"])
        XCTAssertEqual(t.map(\.direction), ["N", "S"])
        XCTAssertEqual(f.terminals(atPier: "sif:whitehall").map(\.direction), ["N"])
    }

    /// With a long walk only the nearest stop of each route and direction is kept: a farther stop stays when it adds one
    func testNearestStopPerRouteAndDirection() {
        func pier(_ id: String, _ lat: Double) -> FerryFeed.Pier { FerryFeed.Pier(id: id, name: "Stop " + id, lat: lat, lon: -74.0) }
        func trip(_ id: String, _ route: String, _ direction: String, _ stops: [String]) -> FerryFeed.Trip {
            FerryFeed.Trip(id: id, route: route, service: "s", direction: direction, stops: stops,
                           times: stops.indices.map { 25_200 + $0 * 120 })
        }
        let f = FerryFeed(versions: ["njb": "20261101"], routes: [],
                          piers: ["a", "b", "c", "d", "e"].enumerated().map { pier($1, 40.70 + Double($0) * 0.004) },
                          trips: [trip("1", "R1", "N", ["a", "b", "c", "e"]), trip("2", "R1", "S", ["e", "c", "b", "a"]),
                                  trip("3", "R2", "N", ["b", "d", "e"]), trip("4", "R3", "S", ["d", "e"])],
                          services: [:], shapes: [:])
        let near = f.stations(near: Coordinate(latitude: 40.70, longitude: -74.0), radiusMeters: 3000)
        XCTAssertEqual(near.map(\.id), ["a", "b", "c", "d", "e"])
        // a: R1 north (R1 south ends there); b adds R1 south and R2 north; c adds nothing; d adds R3 south; e adds nothing
        XCTAssertEqual(f.nearestPerRouteDirection(near).map(\.id), ["a", "b", "d"])
        XCTAssertEqual(f.nearestPerRouteDirection(Array(near.reversed())).map(\.id), ["e", "d", "c"])
        XCTAssertTrue(f.nearestPerRouteDirection([]).isEmpty)
    }

    /// When one operator's data is bad (or failed to download), the other works as usual; error when neither has any.
    func testBuildSkipsBrokenSource() throws {
        var broken = sifFiles
        broken.removeValue(forKey: "stop_times.txt")
        let f = try FerryBuilder.build([.nycFerry: nycFiles, .statenIsland: broken])
        XCTAssertEqual(f.sources, [.nycFerry])
        XCTAssertEqual(f.routes.map(\.id), ["NYF-ER"])
        XCTAssertFalse(f.piers.contains { $0.id.hasPrefix("sif:") }, "The failing operator leaves no partial data behind")
        XCTAssertEqual(try FerryBuilder.build(nyc: nil, sif: sifFiles).sources, [.statenIsland])
        XCTAssertThrowsError(try FerryBuilder.build([:]))
        XCTAssertThrowsError(try FerryBuilder.build([.statenIsland: broken]))
        // The caller is told which operator was skipped and why, also when nothing could be built; never of a good one
        var skipped: [FerryFeed.Source: TimetableError] = [:]
        _ = try FerryBuilder.build([.nycFerry: nycFiles, .statenIsland: broken]) { skipped[$0] = $1 as? TimetableError }
        XCTAssertEqual(skipped, [.statenIsland: .missingFile("stop_times.txt")])
        skipped = [:]
        XCTAssertThrowsError(try FerryBuilder.build([.statenIsland: broken]) { skipped[$0] = $1 as? TimetableError })
        XCTAssertEqual(skipped, [.statenIsland: .missingFile("stop_times.txt")])
        skipped = [:]
        _ = try FerryBuilder.build([.nycFerry: nycFiles, .statenIsland: sifFiles]) { skipped[$0] = $1 as? TimetableError }
        XCTAssertEqual(skipped, [:])
    }

    /// Only one operator downloaded this time: fill in the missing one from what was saved last time, same as if both downloaded.
    func testFillingMissingSourceFromOldData() throws {
        let full = try feed()
        let nycOnly = try FerryBuilder.build(nyc: nycFiles, sif: nil)
        let merged = nycOnly.filling(missingSourcesFrom: full)
        XCTAssertEqual(merged.sources, [.nycFerry, .statenIsland])
        XCTAssertEqual(Set(merged.routes.map(\.id)), Set(full.routes.map(\.id)))
        XCTAssertEqual(Set(merged.piers.map(\.id)), Set(full.piers.map(\.id)))
        XCTAssertEqual(Set(merged.trips.map(\.id)), Set(full.trips.map(\.id)))
        XCTAssertEqual(merged.services, full.services)
        XCTAssertEqual(merged.shapes, full.shapes)
        XCTAssertEqual(merged.versions, full.versions)
        XCTAssertEqual(full.filling(missingSourcesFrom: nycOnly), full, "Unchanged when nothing is missing")
        // Filled-in trips still yield departure times (2026-10-05 is a Monday, with an 8:00 sailing at Whitehall)
        let day = 20261005
        let mergedTimes = merged.arrivals(pierIDs: ["sif:whitehall"], from: ny(day, 7, 0), to: ny(day, 9, 0)).map(\.arrivalTime)
        XCTAssertEqual(mergedTimes, [ny(day, 8, 0)])
        XCTAssertEqual(mergedTimes, full.arrivals(pierIDs: ["sif:whitehall"], from: ny(day, 7, 0), to: ny(day, 9, 0)).map(\.arrivalTime))
    }

    func testMapUsesSubwayMapFormat() throws {
        let m = try feed().map()
        XCTAssertEqual(Set(m.routes.map(\.route)), ["NYF-ER", "SIF"])
        XCTAssertTrue(m.stations.contains { $0.id == "sif:stgeorge" })
        XCTAssertFalse(m.stations.contains { $0.id == "nyf:99" })
    }

    /// NY Waterway and Seastreak: each combined into one route; trips and piers too far from New York are dropped; without a direction, judged by heading to Manhattan.
    func testOtherOperatorsMergeRoutesAndDropFarTrips() throws {
        let f = try allFour()
        XCTAssertEqual(f.routes.map(\.id).sorted(), ["NYF-ER", "NYW", "SIF", "SST"])
        XCTAssertEqual(f.sources, [.nycFerry, .statenIsland, .nyWaterway, .seastreak])
        XCTAssertEqual(f.route("NYW")?.name, "NY Waterway")
        XCTAssertEqual(f.route("NYW")?.color, "C8102E", "After combining into one route, use a fixed color matching the route logo")
        XCTAssertEqual(f.route("NYW")?.realtime, true)
        XCTAssertEqual(f.route("SST")?.name, "Seastreak")
        XCTAssertEqual(f.route("SST")?.color, "013067")
        XCTAssertEqual(f.route("SST")?.realtime, false)
        XCTAssertEqual(f.route("SIF")?.name, "Staten Island Ferry")
        XCTAssertEqual(f.versions["nyw"], "20261013")
        XCTAssertEqual(f.versions["sst"], "20200920", "Use the start date when there's no feed_version")
        // Martha's Vineyard is dropped along with its pier; Haverstraw–Ossining on the upper Hudson is in the metro area, so keep it
        XCTAssertFalse(f.trips.contains { $0.id == "sst:12247_0_0" })
        XCTAssertTrue(f.trips.contains { $0.id == "nyw:7698" })
        XCTAssertEqual(f.pier(id: "nyw:8")?.name, "Haverstraw")
        XCTAssertNil(f.pier(id: "sst:184"))
        XCTAssertNil(f.pier(id: "sst:186"))
        XCTAssertNotNil(f.pier(id: "sst:176"), "Highlands, New Jersey is within the New York surrounding area")
        XCTAssertNotNil(f.pier(id: "nyw:30"), "The South Amboy boat also stops in Manhattan")
        XCTAssertEqual(f.pier(id: "sst:9825")?.name, "Brookfield Place, NY", "A comma in the name (quoted) is read normally")
        // NY Waterway has direction_id; Seastreak doesn't: heading to Manhattan is N, leaving is S
        XCTAssertEqual(f.trips.first { $0.id == "nyw:3636" }?.direction, "N")
        XCTAssertEqual(f.trips.first { $0.id == "nyw:3637" }?.direction, "S")
        XCTAssertEqual(f.trips.first { $0.id == "sst:13182_0_0" }?.direction, "N")
        XCTAssertEqual(f.trips.first { $0.id == "sst:13183_0_0" }?.direction, "S")
        XCTAssertEqual(f.trips.first { $0.id == "sst:13190_0_0" }?.direction, "N")
        XCTAssertEqual(f.trips.first { $0.id == "sst:13230_0_0" }?.direction, "S")
        XCTAssertEqual(f.trips.first { $0.id == "sst:13182_0_0" }?.stops, ["sst:176", "sst:170", "sst:168"],
                       "Order is kept even when stop_sequence starts at 3")
        // Map: the same line in the opposite direction is drawn only once
        XCTAssertEqual(f.shapes["NYW"]?.count, 5)
        XCTAssertEqual(f.shapes["SST"]?.count, 4)
        let m = f.map()
        XCTAssertTrue(m.stations.allSatisfy { ServiceArea.contains(Coordinate(latitude: $0.lat, longitude: $0.lon)) })
        XCTAssertEqual(Set(m.routes.map(\.route)), ["NYF-ER", "NYW", "SIF", "SST"])
        // List all the terminals out from the W 39th St pier (not just the most common one)
        XCTAssertEqual(f.terminals(atPier: "nyw:14").map(\.terminal), ["Edgewater Ferry Landing", "Port Imperial / Weehawken"])
        // Seastreak is timetable-only, with dates only in calendar_dates.txt
        let day = 20261014
        let bmb = f.arrivals(pierIDs: ["sst:170"], from: ny(day, 5, 0), to: ny(day, 23, 0))
        XCTAssertEqual(bmb.map(\.arrivalTime), [ny(day, 6, 25), ny(day, 17, 20)])
        XCTAssertEqual(bmb.map { $0.direction.terminal }, ["East 35th St., NYC", "Atlantic Highlands, NJ"])
        XCTAssertTrue(bmb.allSatisfy { $0.source == .scheduled && $0.route == "SST" })
        XCTAssertTrue(f.arrivals(pierIDs: ["sst:170"], from: ny(20261016, 5, 0), to: ny(20261016, 23, 0)).isEmpty,
                      "This day isn't in calendar_dates.txt")
        XCTAssertEqual(try FerryFeed.decode(f.encoded()), f)
    }

    /// Operators at the same pier combine into one station complex: Pier 11 (NYC Ferry and NY Waterway have identical coordinates) uses NYC Ferry's name,
    /// Brookfield Place (NY Waterway and Seastreak 16 m apart) uses NY Waterway's name; the map draws only one dot.
    func testSamePierFromSeveralOperatorsIsOneStation() throws {
        let f = try allFour()
        let groups = f.pierGroups()
        XCTAssertEqual(groups["nyw:18"]?.group, "ferry:nyf:87")
        XCTAssertEqual(groups["nyw:18"]?.name, "Wall St/Pier 11")
        XCTAssertEqual(groups["nyf:87"]?.group, "ferry:nyf:87")
        XCTAssertEqual(groups["sst:9825"]?.group, "ferry:nyw:4")
        XCTAssertEqual(groups["sst:9825"]?.name, "Brookfield Place Terminal")
        XCTAssertNil(groups["nyf:20"], "A pier with only one operator isn't grouped")
        let here = Coordinate(latitude: 40.7035, longitude: -74.0)
        let near = f.stations(near: here, radiusMeters: 1500)
        let p11 = near.filter { $0.complexID == "ferry:nyf:87" }
        XCTAssertEqual(Set(p11.map(\.id)), ["nyf:87", "nyw:18"])
        XCTAssertTrue(p11.allSatisfy { $0.name == "Wall St/Pier 11" })
        XCTAssertNil(near.first { $0.id == "nyf:20" }?.complexID)
        let m = f.map()
        XCTAssertTrue(m.stations.contains { $0.id == "nyf:87" })
        XCTAssertFalse(m.stations.contains { $0.id == "nyw:18" })
        XCTAssertTrue(m.stations.contains { $0.id == "nyw:4" && $0.name == "Brookfield Place Terminal" })
        XCTAssertFalse(m.stations.contains { $0.id == "sst:9825" })
        // One pier in the departure board, with both operators' boats in it
        let day = 20261014
        let leave = ny(day, 6, 20)
        let arrivals = f.arrivals(pierIDs: near.map(\.id), from: leave, to: ny(day, 9, 0))
        let walks = Dictionary(uniqueKeysWithValues: near.map { s in
            (s.id, WalkEstimator.estimate(from: here, to: s, settings: .default, routeMeters: nil))
        })
        let board = NearbyBoardBuilder.build(stations: near, walks: walks, arrivals: arrivals, settings: .default, now: leave)
        let pier = board.stations.first { $0.id == "cferry:nyf:87" }
        XCTAssertEqual(pier?.name, "Wall St/Pier 11")
        let trains = [pier?.north, pier?.south].compactMap { $0 }.flatMap(\.trains)
        XCTAssertEqual(Set(trains.map(\.route)), ["NYF-ER", "NYW"])
    }

    /// Seastreak's Battery Maritime Building Slip 5 is about 100 m from Staten Island Ferry's Whitehall, in a separate building next door:
    /// don't merge, each keeps its own name (otherwise Seastreak boats would show under "Whitehall Ferry Terminal").
    func testNeighbouringTerminalsStaySeparate() throws {
        let f = try allFour()
        let whitehall = try XCTUnwrap(f.pier(id: "sif:whitehall"))
        let bmb = try XCTUnwrap(f.pier(id: "sst:170"))
        XCTAssertEqual(WalkEstimator.distanceMeters(whitehall.coordinate, bmb.coordinate), 103, accuracy: 10)
        let groups = f.pierGroups()
        XCTAssertNil(groups["sif:whitehall"])
        XCTAssertNil(groups["sst:170"])
        let near = f.stations(near: Coordinate(latitude: 40.7012, longitude: -74.0122), radiusMeters: 300)
        XCTAssertEqual(Set(near.map(\.id)), ["sif:whitehall", "sst:170"])
        XCTAssertEqual(near.first { $0.id == "sst:170" }?.name, "Battery Maritime Building Slip 5")
        XCTAssertEqual(near.first { $0.id == "sif:whitehall" }?.name, "Whitehall Ferry Terminal")
        XCTAssertTrue(near.allSatisfy { $0.complexID == nil })
        XCTAssertTrue(f.map().stations.contains { $0.id == "sst:170" })
    }

    /// The place search finds a timetable's stations by name from a small list kept beside it: one entry for each station where a
    /// trip can be boarded, piers that are one station under their shared name with the routes of them all
    func testStationNamesForThePlaceSearch() throws {
        let f = try allFour()
        let names = StationNames.of(f)
        XCTAssertFalse(names.isEmpty)
        XCTAssertEqual(names.count, Set(names.map(\.id)).count)
        let boarding = f.routesByPier()
        XCTAssertTrue(names.allSatisfy { boarding[$0.id] != nil }, "Only piers where a trip can be boarded")
        XCTAssertTrue(names.allSatisfy { $0.routes == $0.routes.sorted() && !$0.routes.isEmpty })
        let pier11 = names.filter { $0.name == "Wall St/Pier 11" }
        XCTAssertEqual(pier11.count, 1, "One entry for the piers that are one station")
        XCTAssertTrue(Set(pier11.first?.routes ?? []).isSuperset(of: ["NYF-ER", "NYW"]))
        // Neighbouring terminals stay two entries, each under its own name
        XCTAssertEqual(names.first { $0.id == "sst:170" }?.name, "Battery Maritime Building Slip 5")
        XCTAssertEqual(names.first { $0.id == "sif:whitehall" }?.name, "Whitehall Ferry Terminal")
        // Saved and read back as it is
        let data = try JSONEncoder().encode(names)
        XCTAssertEqual(try JSONDecoder().decode([StationName].self, from: data), names)
        XCTAssertTrue(StationNames.matching("pier 11", in: names, limit: 4).contains { $0.name == "Wall St/Pier 11" })
    }

    /// Names starting with the text first, then the others, each in name order with numbers by their value; case and accents
    /// aside; at least two characters; at most the limit
    func testStationNamesMatching() {
        func s(_ id: String, _ name: String) -> StationName {
            StationName(id: id, name: name, coordinate: Coordinate(latitude: 40.7, longitude: -74), routes: [])
        }
        let list = [s("a", "Park Pl"), s("b", "Central Park North"), s("c", "Parkchester"), s("d", "Bowling Green"), s("e", "Caf\u{E9} Park"),
                    s("f", "14 St"), s("g", "103 St"), s("h", "Park Pl")]
        XCTAssertEqual(StationNames.matching("park", in: list, limit: 10).map(\.id), ["a", "h", "c", "e", "b"])
        XCTAssertEqual(StationNames.matching("PARK", in: list, limit: 2).map(\.id), ["a", "h"])
        XCTAssertEqual(StationNames.matching("cafe", in: list, limit: 10).map(\.id), ["e"])
        XCTAssertEqual(StationNames.matching("st", in: list, limit: 10).map(\.id), ["f", "g", "c"])
        XCTAssertEqual(StationNames.matching("  bo  ", in: list, limit: 10).map(\.id), ["d"])
        XCTAssertEqual(StationNames.matching("p", in: list, limit: 10), [], "One character is still being typed")
        XCTAssertEqual(StationNames.matching("xyz", in: list, limit: 10), [])
    }

    /// Drop-off-only piers (pickup_type 1): NY Waterway's Edgewater-to-Midtown boat only drops off at Port Imperial,
    /// so that sailing isn't shown at Port Imperial; it shows normally at Edgewater.
    func testDropOffOnlyStopIsNotShown() throws {
        let f = try allFour()
        XCTAssertEqual(f.trips.first { $0.id == "nyw:7463" }?.noBoarding, [1])
        XCTAssertNil(f.trips.first { $0.id == "nyw:3636" }?.noBoarding)
        XCTAssertNil(f.trips.first { $0.id == "sst:13183_0_0" }?.noBoarding, "The terminal can't be boarded anyway, no need to record it")
        let day = 20261014
        let pi = f.arrivals(pierIDs: ["nyw:11"], from: ny(day, 5, 0), to: ny(day, 9, 0))
        XCTAssertEqual(pi.map(\.id), ["nyw:3636|\(day)|nyw:11"], "7463 only drops off here")
        let edgewater = f.arrivals(pierIDs: ["nyw:5"], from: ny(day, 5, 0), to: ny(day, 9, 0))
        XCTAssertEqual(edgewater.map(\.id), ["nyw:7463|\(day)|nyw:5"])
        XCTAssertEqual(edgewater.first?.direction.terminal, "Midtown / W. 39th St.")
        XCTAssertEqual(f.terminals(atPier: "nyw:11").map(\.terminal), ["Midtown / W. 39th St."])
        XCTAssertEqual(f.routesByPier()["nyw:11"], ["NYW"])
        // Same after saving and reading back; previously saved data without this field still reads normally
        XCTAssertEqual(try FerryFeed.decode(f.encoded()), f)
        let old = #"{"id":"nyw:1","route":"NYW","service":"nyw:6","direction":"N","stops":["nyw:11","nyw:14"],"times":[0,600]}"#
        let trip = try JSONDecoder().decode(FerryFeed.Trip.self, from: Data(old.utf8))
        XCTAssertNil(trip.noBoarding)
        XCTAssertTrue(trip.canBoard(at: 0))
        XCTAssertFalse(trip.canBoard(at: 1), "Can't board at the terminal")
    }

    /// NY Waterway calendar: calendar.txt (days of the week) plus the suspension day (Christmas) in calendar_dates.txt.
    func testNYWaterwayHolidayRemoval() throws {
        let f = try allFour()
        // Thursday 2026-12-24 runs as usual; Friday 12-25 is suspended
        XCTAssertEqual(f.arrivals(pierIDs: ["nyw:10"], from: ny(20261224, 5, 0), to: ny(20261224, 9, 0)).map(\.arrivalTime),
                       [ny(20261224, 6, 20)])
        XCTAssertTrue(f.arrivals(pierIDs: ["nyw:10"], from: ny(20261225, 5, 0), to: ny(20261225, 9, 0)).isEmpty)
        XCTAssertTrue(f.arrivals(pierIDs: ["nyw:10"], from: ny(20261017, 5, 0), to: ny(20261017, 9, 0)).isEmpty, "No weekday trips on Saturday")
    }

    func testOtherOperatorBadgesAndRealtimeSources() {
        XCTAssertTrue(FerryFeed.isFerryRoute("NYW"))
        XCTAssertTrue(FerryFeed.isFerryRoute("SST"))
        XCTAssertFalse(FerryFeed.isFerryRoute("NYWX"))
        XCTAssertEqual(FerryFeed.badge("NYW"), "NYW")
        XCTAssertEqual(FerryFeed.badge("SST"), "SEA")
        XCTAssertEqual(FerryFeed.routeName("NYF-ER"), "NYC Ferry East River")
        XCTAssertEqual(FerryFeed.routeName("SST"), "Seastreak")
        XCTAssertEqual(FerryFeed.Source.of(route: "SIF"), .statenIsland)
        XCTAssertEqual(FerryFeed.realtimeSources(routes: ["SIF", "SST", "NYW"]), [.nyWaterway])
        XCTAssertEqual(FerryFeed.realtimeSources(routes: ["NYW", "NYF-ER"]), [.nycFerry, .nyWaterway])
        XCTAssertEqual(FerryFeed.realtimeSources(routes: ["SIF"]), [])
    }

    /// Hover and screen readers get a name for every kind of route, never an internal ID
    func testSpokenRouteName() {
        XCTAssertEqual(FerryFeed.spokenRouteName("LIRR-BAB"), "LIRR Babylon Branch")
        XCTAssertEqual(FerryFeed.spokenRouteName("NJB-107"), "NJ Transit Bus 107")
        XCTAssertEqual(FerryFeed.spokenRouteName("NJB-SCT/1"), "Suffolk County Transit 1")
        XCTAssertEqual(FerryFeed.spokenRouteName("NYF-ER"), "NYC Ferry East River")
        XCTAssertEqual(FerryFeed.spokenRouteName("SST"), "Seastreak")
        XCTAssertEqual(FerryFeed.spokenRouteName(RooseveltIslandTram.route), "Roosevelt Island Tram")
        XCTAssertEqual(FerryFeed.spokenRouteName("M15+"), "M15-SBS")
        XCTAssertEqual(FerryFeed.spokenRouteName("Bx12"), "Bx12")
        XCTAssertEqual(FerryFeed.spokenRouteName("GS"), "S")
        XCTAssertEqual(FerryFeed.spokenRouteName("6X"), "6")
        XCTAssertEqual(FerryFeed.spokenRouteName("SI"), "SIR")
        XCTAssertEqual(FerryFeed.spokenRouteName("A"), "A")
    }

    /// Each operator's realtime data stays separate: a same-named trip in NY Waterway's data doesn't affect NYC Ferry's trip.
    func testRealtimeFromTwoOperators() throws {
        let f = try allFour()
        let day = 20261014
        let now = ny(day, 6, 15)
        // NYC Ferry's t1 is expected to leave Pier 11 2 minutes late, carried over to the next stop
        let nyf = FerryRealtime(timestamp: now, trips: [
            "t1": .init(stopTimes: [.init(stopID: "87", time: ny(day, 8, 2))]),
        ], fetchedAt: now)
        let nyw = FerryRealtime(timestamp: now, trips: [
            "3637": .init(stopTimes: [.init(stopID: "14", time: ny(day, 6, 24))]),
            "t1": .init(stopTimes: [], canceled: true),
        ], fetchedAt: now, source: .nyWaterway)
        let list = f.arrivals(pierIDs: ["nyw:14", "nyf:20"], from: now, to: ny(day, 12, 0), realtime: [nyf, nyw], now: now)
        let w = list.first { $0.id.hasPrefix("nyw:3637|") }
        XCTAssertEqual(w?.arrivalTime, ny(day, 6, 24))
        XCTAssertEqual(w?.source, .realtime)
        XCTAssertEqual(w?.route, "NYW")
        XCTAssertEqual(w?.direction.terminal, "Port Imperial / Weehawken")
        let t1 = list.first { $0.id.hasPrefix("nyf:t1|") }
        XCTAssertEqual(t1?.arrivalTime, ny(day, 8, 12), "NY Waterway's t1 is cancelled, which doesn't affect NYC Ferry's t1")
        XCTAssertEqual(t1?.source, .realtime)
        XCTAssertEqual(list.first { $0.id.hasPrefix("nyw:7464|") }?.source, .scheduled)
        XCTAssertEqual(list.first { $0.id.hasPrefix("nyw:7464|") }?.direction.terminal, "Edgewater Ferry Landing")
        // Realtime data for only one operator: the other uses the timetable throughout
        let nyfOnly = f.arrivals(pierIDs: ["nyw:14"], from: now, to: ny(day, 12, 0), realtime: nyf, now: now)
        XCTAssertFalse(nyfOnly.isEmpty)
        XCTAssertTrue(nyfOnly.allSatisfy { $0.source == .scheduled })
    }

    // MARK: Statue of Liberty ferry

    /// Loops are kept; leaving the origin, the destination is the next stop; security screening adds 30 minutes to the judgment.
    func testStatueOfLibertyLoopsAndBoardingTime() throws {
        let f = try FerryBuilder.build(nyc: nil, sif: nil, sol: solFiles)
        XCTAssertEqual(f.routes.map(\.id), ["SOL"])
        XCTAssertEqual(f.route("SOL")?.name, "Statue of Liberty Ferry")
        XCTAssertEqual(f.route("SOL")?.color, "2E8B57")
        XCTAssertEqual(f.route("SOL")?.realtime, false)
        XCTAssertEqual(f.sources, [.statueOfLiberty])
        XCTAssertEqual(f.versions["sol"], "20260908")
        XCTAssertEqual(FerryFeed.badge("SOL"), "SOL")
        XCTAssertEqual(FerryFeed.routeName("SOL"), "Statue of Liberty Ferry")
        XCTAssertEqual(f.trips.count, 5, "Keep the loops too (Staten Island Ferry's loops are still dropped)")
        XCTAssertTrue(f.trips.allSatisfy { $0.direction == "S" }, "direction_id is always 1")
        XCTAssertEqual(f.pier(id: "sol:LI")?.name, "Liberty Island")
        XCTAssertEqual(f.shapes["SOL"]?.count, 2, "Two loops; the evening return boats' piers are all on the loops, so no extra straight lines")

        // Thursday (in season): only the New York loop leaves Battery Park, destination is the next stop; evening return boats end here and aren't shown
        let thursday = 20261001
        let bp = f.arrivals(pierIDs: ["sol:BP"], from: ny(thursday, 0, 0), to: ny(thursday, 23, 59))
        XCTAssertEqual(bp.map(\.arrivalTime), [ny(thursday, 9, 0)])
        XCTAssertEqual(bp.first?.direction.terminal, "Liberty Island")
        XCTAssertEqual(bp.first?.route, "SOL")
        XCTAssertEqual(bp.first?.source, .scheduled)
        // Saturday also has weekend sailings
        let saturday = f.arrivals(pierIDs: ["sol:BP"], from: ny(20261003, 0, 0), to: ny(20261003, 23, 59))
        XCTAssertEqual(saturday.map(\.arrivalTime), [ny(20261003, 9, 0), ny(20261003, 9, 30)])
        // Liberty Island: the New York loop returns to Battery Park, the New Jersey loop to Liberty State Park; evening return boats show the terminal
        let li = f.arrivals(pierIDs: ["sol:LI"], from: ny(thursday, 0, 0), to: ny(thursday, 23, 59))
        XCTAssertEqual(li.map(\.arrivalTime), [ny(thursday, 9, 10), ny(thursday, 9, 20), ny(thursday, 16, 50), ny(thursday, 17, 0)])
        XCTAssertEqual(li.map { $0.direction.terminal ?? "" },
                       ["Liberty State Park", "Battery Park", "Liberty State Park", "Battery Park"])
        // Same for the direction titles when there are no boats
        XCTAssertEqual(f.terminals(atPier: "sol:BP").map(\.terminal), ["Liberty Island"])
        XCTAssertEqual(Set(f.terminals(atPier: "sol:LI").map(\.terminal)), ["Battery Park", "Liberty State Park"])

        // Tickets and security before boarding: allow 30 extra minutes from reaching the pier to boarding (other operators still 1 minute)
        let near = f.stations(near: Coordinate(latitude: 40.7016, longitude: -74.0162), radiusMeters: 200)
        XCTAssertEqual(near.map(\.id), ["sol:BP"])
        XCTAssertEqual(near.first?.entranceToPlatformSeconds, 30 * 60)
        XCTAssertTrue(FerryFeed.Source.statueOfLiberty.needsSecurityCheck)
        XCTAssertFalse(FerryFeed.Source.nycFerry.needsSecurityCheck)
        XCTAssertEqual(FerryFeed.Source.seastreak.boardingSeconds, 60)
        XCTAssertEqual(FerryFeed.realtimeSources(routes: ["SOL"]), [])
        XCTAssertEqual(try FerryFeed.decode(f.encoded()), f)
    }

    /// Timetable has run out (the season ended 2026-10-12 and the new one isn't published yet): its piers and routes aren't shown; other operators as usual.
    func testIdleOperatorIsHiddenUntilNewTimetable() throws {
        let f = try FerryBuilder.build(nyc: nycFiles, sif: sifFiles, sol: solFiles)
        let inSeason = ny(20261001, 12, 0)
        XCTAssertEqual(f.idleSources(from: inSeason), [])
        XCTAssertEqual(f.active(from: inSeason), f, "Returned unchanged when everything is running")
        XCTAssertEqual(f.idleSources(from: ny(20261012, 23, 0)), [], "There are still boats on the last day")
        let today = ny(20261014, 12, 0)
        XCTAssertEqual(f.idleSources(from: today), [.statueOfLiberty])
        let active = f.active(from: today)
        XCTAssertFalse(active.piers.contains { $0.id.hasPrefix("sol:") })
        XCTAssertFalse(active.trips.contains { $0.id.hasPrefix("sol:") })
        XCTAssertFalse(active.services.keys.contains { $0.hasPrefix("sol:") })
        XCTAssertNil(active.route("SOL"))
        XCTAssertNil(active.shapes["SOL"])
        XCTAssertNil(active.versions["sol"])
        XCTAssertTrue(active.stations(near: Coordinate(latitude: 40.7016, longitude: -74.0162), radiusMeters: 200).isEmpty,
                      "Empty piers with no boats aren't shown")
        XCTAssertFalse(active.map().routes.contains { $0.route == "SOL" })
        XCTAssertEqual(active.routes.map(\.id).sorted(), ["NYF-ER", "SIF"], "Other operators as usual")
        XCTAssertEqual(active.sources, [.nycFerry, .statenIsland])
        // After a new season is published: shown starting a week before it begins (Plan a Trip uses the departure day, so later days can be queried)
        var nextSeason = solFiles
        nextSeason["calendar.txt"] = d("""
        service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
        fall,1,1,1,1,1,1,1,20261022,20270131
        weekend,0,0,0,0,0,1,1,20261022,20270131
        weekday,1,1,1,1,1,0,0,20261022,20270131
        """)
        let renewed = try FerryBuilder.build(nyc: nycFiles, sif: sifFiles, sol: nextSeason)
        XCTAssertEqual(renewed.idleSources(from: today), [.statueOfLiberty], "Starts only on 10/22, so no boats in the week from 10/14")
        XCTAssertEqual(renewed.idleSources(from: ny(20261016, 8, 0)), [])
        // From a week before its last boats a new timetable is checked for every day (see FerryFeed.endingSoonDays)
        XCTAssertEqual(f.endingSoonSources(from: ny(20261005, 12, 0)), [], "Its last boats, on 10/12, are a week away")
        XCTAssertEqual(f.endingSoonSources(from: ny(20261006, 12, 0)), [.statueOfLiberty], "Its last boats are within the next 7 days")
        XCTAssertEqual(f.endingSoonSources(from: today), [.statueOfLiberty])
        XCTAssertEqual(renewed.endingSoonSources(from: today), [], "The new season starts within the two weeks after them")
        // The saved small result matches what the full data computes (Settings uses it, without reading the whole timetable)
        for (feed, day) in [(f, inSeason), (f, today), (renewed, today), (renewed, ny(20261016, 8, 0))] {
            let c = try FerryFeed.Coverage.decodeRoundTrip(feed.coverage(from: day))
            XCTAssertTrue(c.isUsable(from: day))
            XCTAssertEqual(c.idleSources(from: day), feed.idleSources(from: day))
            XCTAssertEqual(c.endingSources(from: day), feed.endingSources(from: day))
            XCTAssertEqual(c.endingSoonSources(from: day), feed.endingSoonSources(from: day))
        }
        XCTAssertEqual(renewed.active(from: ny(20261023, 9, 0)).route("SOL")?.name, "Statue of Liberty Ferry")
    }

    /// NYC Ferry writes Governors Island as "Gov. Island/Yankee Pier": spell it out.
    func testGovernorsIslandNameWrittenOut() {
        XCTAssertEqual(FerryBuilder.pierName("Gov. Island/Yankee Pier"), "Governors Island/Yankee Pier")
        XCTAssertEqual(FerryBuilder.pierName("Wall St/Pier 11"), "Wall St/Pier 11")
    }

    /// The boats around Greater Boston (all timetable only, each one line): Vineyard Fast Ferry's boats back from Oak Bluffs are
    /// a route the data marks as a bus, and they are kept; the piers' names lose the National Park Service's codes and Patriot
    /// Party Boats' street address; a trip with a pier outside the operator's metro areas is dropped (Seastreak's island boats,
    /// in New York's data, stay out in testOtherOperatorsMergeRoutesAndDropFarTrips)
    func testGreaterBostonFerries() throws {
        let calendar = """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            S,1,1,1,1,1,1,1,20260601,20261231
            """
        let vff: [String: Data] = [
            "routes.txt": d("""
                route_id,agency_id,route_short_name,route_long_name,route_type
                2099,281,,Vineyard Fast Ferry,4
                2100,281,,Vineyard Fast Ferry,3
                """),
            "stops.txt": d("""
                stop_id,stop_name,stop_lat,stop_lon
                Q,"Quonset Point Pier, Quonset Point, RI",41.5867,-71.4128
                O,"Oak Bluffs, Martha's Vineyard, MA",41.4588,-70.5544
                """),
            "trips.txt": d("""
                route_id,service_id,trip_id,trip_headsign,direction_id
                2099,S,out,Martha's Vineyard,0
                2100,S,back,Quonset,0
                """),
            "stop_times.txt": d("""
                trip_id,arrival_time,departure_time,stop_id,stop_sequence
                out,08:30:00,08:30:00,Q,0
                out,10:15:00,10:15:00,O,1
                back,10:45:00,10:45:00,O,0
                back,12:30:00,12:30:00,Q,1
                """),
            "calendar.txt": d(calendar),
        ]
        let bhi: [String: Data] = [
            "routes.txt": d("""
                route_id,agency_id,route_short_name,route_long_name,route_type,route_color
                SI,NPS,,Spectacle Island,4,436E2E
                """),
            "stops.txt": d("""
                stop_id,stop_name,stop_lat,stop_lon
                1,Long Wharf (LW),42.3605,-71.0505
                3,Spectacle Island (SI),42.3270,-70.9840
                9,Far Pier,40.7000,-74.0170
                """),
            "trips.txt": d("""
                route_id,service_id,trip_id,direction_id
                SI,S,t1,0
                SI,S,t2,1
                SI,S,far,0
                """),
            "stop_times.txt": d("""
                trip_id,arrival_time,departure_time,stop_id,stop_sequence
                t1,09:00:00,09:00:00,1,1
                t1,09:30:00,09:30:00,3,2
                t2,10:00:00,10:00:00,3,1
                t2,10:30:00,10:30:00,1,2
                far,11:00:00,11:00:00,1,1
                far,13:00:00,13:00:00,9,2
                """),
            "calendar.txt": d(calendar),
        ]
        let f = try FerryBuilder.build([.vineyardFastFerry: vff, .harborIslands: bhi], now: ny(20260801, 12, 0))
        XCTAssertEqual(f.routes.map(\.id), ["VFF", "BHI"])
        XCTAssertEqual(f.route("VFF")?.name, "Vineyard Fast Ferry")
        XCTAssertEqual(f.route("VFF")?.color, "005A70")
        XCTAssertEqual(f.route("BHI")?.color, "BF5700", "One line in one color, whatever each route's color in the data")
        XCTAssertEqual(Set(f.trips.map(\.id)), ["vff:out", "vff:back", "bhi:t1", "bhi:t2"], "The boat to a pier in New York's area is dropped")
        XCTAssertNil(f.pier(id: "bhi:9"))
        XCTAssertEqual(f.terminals(atPier: "vff:O").map(\.terminal), ["Quonset Point Pier, Quonset Point, RI"])
        XCTAssertEqual(f.pier(id: "bhi:1")?.name, "Long Wharf")
        XCTAssertEqual(f.pier(id: "bhi:3")?.name, "Spectacle Island")
        XCTAssertTrue(f.routes.allSatisfy { $0.realtime == false })
        let day = 20260801
        XCTAssertEqual(f.arrivals(pierIDs: ["vff:O"], from: ny(day, 10, 0), to: ny(day, 11, 0)).map(\.arrivalTime), [ny(day, 10, 45)])
        XCTAssertEqual(FerryBuilder.pierName("227 Clinton St., Falmouth, MA", source: .patriot), "Falmouth, MA")
        XCTAssertEqual(FerryBuilder.pierName("Straight Warf, Nantucket", source: .freedom), "Straight Wharf, Nantucket")
        XCTAssertEqual(FerryBuilder.pierName("EDIC Dock, South Boston (EDIC)", source: .cathleenStone), "EDIC Dock, South Boston")
        XCTAssertEqual(FerryBuilder.pierName("Ocean Street Terminal, Hyannis, MA", source: .hyLine), "Ocean Street Terminal, Hyannis, MA")
        // Every one of them is downloaded only for Greater Boston and has no live data (How It Works' timetable line there names them)
        for s in ModeCoverage.ferriesListedTogether {
            XCTAssertEqual(s.downloadArea, .greaterBoston, s.name)
            XCTAssertEqual(MetroArea.areas(of: s), [.greaterBoston], s.name)
            XCTAssertNil(s.builtInRealtimeURL, s.name)
            XCTAssertEqual(s.builtInURL.scheme, "https", s.name)
        }
    }

    /// Each operator's trips count their days and times in its own time zone (agency_timezone), and a pier with its own
    /// (stop_timezone) shows its times in it. The fixture's first operator is given Los Angeles time and one pier Denver time to test
    /// it; the second has no agency.txt (a copy downloaded before it was read) and counts in its metro area's
    func testOperatorsCountInTheirOwnTimeZones() throws {
        let calendar = """
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            S,1,1,1,1,1,1,1,20260601,20261231
            """
        let vff: [String: Data] = [
            "agency.txt": d("""
                agency_id,agency_name,agency_url,agency_timezone
                281,Test Ferry,https://example.com,America/Los_Angeles
                """),
            "routes.txt": d("""
                route_id,agency_id,route_short_name,route_long_name,route_type
                2099,281,,Vineyard Fast Ferry,4
                """),
            "stops.txt": d("""
                stop_id,stop_name,stop_lat,stop_lon,stop_timezone
                Q,"Quonset Point Pier, Quonset Point, RI",41.5867,-71.4128,
                O,"Oak Bluffs, Martha's Vineyard, MA",41.4588,-70.5544,America/Denver
                """),
            "trips.txt": d("""
                route_id,service_id,trip_id,trip_headsign,direction_id
                2099,S,out,Martha's Vineyard,0
                2099,S,late,Martha's Vineyard,0
                2099,S,back,Quonset,1
                """),
            "stop_times.txt": d("""
                trip_id,arrival_time,departure_time,stop_id,stop_sequence
                out,08:30:00,08:30:00,Q,0
                out,10:15:00,10:15:00,O,1
                late,24:40:00,24:40:00,Q,0
                late,26:10:00,26:10:00,O,1
                back,10:45:00,10:45:00,O,0
                back,12:30:00,12:30:00,Q,1
                """),
            "calendar.txt": d(calendar),
        ]
        let bhi: [String: Data] = [
            "routes.txt": d("""
                route_id,agency_id,route_short_name,route_long_name,route_type
                SI,NPS,,Spectacle Island,4
                """),
            "stops.txt": d("""
                stop_id,stop_name,stop_lat,stop_lon
                1,Long Wharf (LW),42.3605,-71.0505
                3,Spectacle Island (SI),42.3270,-70.9840
                """),
            "trips.txt": d("""
                route_id,service_id,trip_id,direction_id
                SI,S,t1,0
                """),
            "stop_times.txt": d("""
                trip_id,arrival_time,departure_time,stop_id,stop_sequence
                t1,11:00:00,11:00:00,1,1
                t1,11:30:00,11:30:00,3,2
                """),
            "calendar.txt": d(calendar),
        ]
        let f = try FerryBuilder.build([.vineyardFastFerry: vff, .harborIslands: bhi], now: ny(20260801, 12, 0))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(f.zones, ["vff:": "America/Los_Angeles"])
        XCTAssertEqual(f.pier(id: "vff:O")?.timeZone, "America/Denver")
        XCTAssertNil(f.pier(id: "vff:Q")?.timeZone, "the operator's own isn't repeated")
        XCTAssertEqual(f.timeZone(ofTrip: "vff:out"), losAngeles)
        XCTAssertEqual(f.timeZone(ofTrip: "bhi:t1"), MetroArea.greaterBoston.timeZone)
        func la(_ day: Int, _ h: Int, _ m: Int) throws -> Date {
            try XCTUnwrap(Timetable.serviceDayStart(day, in: losAngeles)).addingTimeInterval(TimeInterval(h * 3600 + m * 60))
        }
        let day = 20260801
        // 8:30 AM in Los Angeles is 11:30 AM in New York, half an hour after the Boston boat
        let mixed = f.arrivals(pierIDs: ["vff:Q", "bhi:1"], from: ny(day, 10, 0), to: ny(day, 12, 0))
        XCTAssertEqual(mixed.map(\.id), ["bhi:t1|\(day)|bhi:1", "vff:out|\(day)|vff:Q"])
        XCTAssertEqual(mixed.map(\.arrivalTime), [ny(day, 11, 0), try la(day, 8, 30)])
        XCTAssertEqual(mixed.map(\.arrivalTime), [ny(day, 11, 0), ny(day, 11, 30)])
        XCTAssertEqual(mixed.map(\.timeZone), [MetroArea.greaterBoston.timeZone.identifier, "America/Los_Angeles"])
        // The pier in Denver time: 10:45 AM in Los Angeles, shown in Denver's
        let oak = f.arrivals(pierIDs: ["vff:O"], from: ny(day, 13, 0), to: ny(day, 14, 0))
        XCTAssertEqual(oak.map(\.arrivalTime), [try la(day, 10, 45)])
        XCTAssertEqual(oak.first?.stationTimeZone?.identifier, "America/Denver")
        // After midnight: the boat at 24:40 on Los Angeles' August 1 leaves at 3:40 AM on August 2 in New York, when New York's
        // August 1 timetable is over
        let night = f.arrivals(pierIDs: ["vff:Q"], from: ny(20260802, 3, 0), to: ny(20260802, 4, 0))
        XCTAssertEqual(night.map(\.id), ["vff:late|\(day)|vff:Q"])
        XCTAssertEqual(night.map(\.arrivalTime), [ny(20260802, 3, 40)])
    }

    /// On a Mac: put the real feeds in CMT_FERRY_DIR (nyc.zip, sif.zip, nyw.zip, sst.zip, sol.zip,
    /// optionally rt.pb = NYC Ferry realtime data, rt-nyw.pb = NY Waterway realtime data) and check they're handled correctly.
    /// If only some are present, only those are checked.
    func testRealFeedsIfAvailable() throws {
        #if canImport(Compression)
        guard let dir = ProcessInfo.processInfo.environment["CMT_FERRY_DIR"] else {
            throw XCTSkip("CMT_FERRY_DIR not set")
        }
        let base = URL(fileURLWithPath: dir)
        func load(_ name: String) throws -> [String: Data]? {
            guard let zip = try? Data(contentsOf: base.appendingPathComponent(name)) else { return nil }
            return try ZipReader.extract(zip, names: FerryFeed.neededFiles)
        }
        let nyc = try load("nyc.zip")
        let sif = try load("sif.zip")
        let nyw = try load("nyw.zip")
        let sst = try load("sst.zip")
        let sol = try load("sol.zip")
        if nyc == nil && sif == nil && nyw == nil && sst == nil && sol == nil { throw XCTSkip("CMT_FERRY_DIR has no ferry zip") }
        let f = try FerryBuilder.build(nyc: nyc, sif: sif, nyw: nyw, sst: sst, sol: sol)
        if nyc != nil {
            XCTAssertTrue(f.routes.contains { $0.id == "NYF-ER" })
            XCTAssertGreaterThan(f.piers.filter { $0.id.hasPrefix("nyf:") }.count, 15)
        }
        if sif != nil {
            XCTAssertTrue(f.routes.contains { $0.id == "SIF" })
        }
        if nyw != nil {
            XCTAssertTrue(f.trips.contains { $0.route == "NYW" }, "NY Waterway should have trips stopping in New York")
        }
        if sst != nil {
            XCTAssertTrue(f.trips.contains { $0.route == "SST" }, "Seastreak should have trips stopping in New York")
        }
        if sol != nil {
            XCTAssertTrue(f.trips.contains { $0.route == "SOL" && $0.stops.first == $0.stops.last }, "The Statue of Liberty ferry loops must be kept")
            XCTAssertNotNil(f.pier(id: "sol:BP"))
            for trip in f.trips where trip.route == "SOL" {
                XCTAssertNotEqual(f.destination(of: trip, at: 0), f.pier(id: trip.stops[0])?.name, "Leaving the origin must not name the origin as the destination")
            }
        }
        if nyc != nil {
            XCTAssertTrue(f.piers.contains { $0.name.hasPrefix("Governors Island") }, "NYC Ferry's Governors Island pier uses the full name")
        }
        XCTAssertFalse(f.piers.contains { $0.name.contains("&amp;") })
        // Every pier in the New York area, NY Waterway's upper Hudson piers (Haverstraw, Ossining) included: the app keeps those routes
        // on purpose (FerryBuilder.staysInItsAreas)
        XCTAssertTrue(f.piers.allSatisfy { (40.35...41.25).contains($0.lat) && (-74.45 ... -73.55).contains($0.lon) })
        let now = Date()
        var rt: [FerryRealtime] = []
        if let pb = try? Data(contentsOf: base.appendingPathComponent("rt.pb")) {
            rt.append(try FerryRealtime.decode(pb, fetchedAt: now))
        }
        if let pb = try? Data(contentsOf: base.appendingPathComponent("rt-nyw.pb")) {
            rt.append(try FerryRealtime.decode(pb, fetchedAt: now, source: .nyWaterway))
        }
        let all = f.arrivals(pierIDs: f.piers.map(\.id), from: now, to: now.addingTimeInterval(3 * 3600), realtime: rt, now: now)
        print("ferry: \(f.routes.count) routes, \(f.piers.count) piers, \(f.trips.count) trips, next 3 h: \(all.count) departures, realtime \(all.filter { (a: Arrival) in a.source == .realtime }.count), json \(try f.encoded().count) bytes")
        for source in FerryFeed.Source.allCases {
            let trips = f.trips.filter { source.owns(id: $0.id) }
            let piers = f.piers.filter { source.owns(id: $0.id) }
            print("ferry \(source.rawValue): \(trips.count) trips, \(piers.count) piers: \(piers.map(\.name).sorted().joined(separator: " | "))")
        }
        // Operators at the same pier (printed, to check they merged correctly)
        let groups = f.pierGroups()
        var byGroup: [String: [String]] = [:]
        for (id, g) in groups { byGroup[g.group, default: []].append(id) }
        for (_, ids) in byGroup.sorted(by: { $0.key < $1.key }) {
            let names = ids.sorted().compactMap { id in f.pier(id: id).map { "\(id) \($0.name)" } }
            print("ferry same pier: \(groups[ids[0]]!.name) = \(names.joined(separator: " + "))")
        }
        print("ferry: \(f.trips.filter { $0.noBoarding != nil }.count) trips have drop-off-only stops")
        print("ferry: idle now (hidden until a new timetable): \(f.idleSources(from: now).map(\.rawValue).sorted())")
        if sif != nil {
            let whitehall = f.stations(near: Coordinate(latitude: 40.7013, longitude: -74.013), radiusMeters: 300)
            XCTAssertTrue(whitehall.contains { $0.id.hasPrefix("sif:") })
            XCTAssertNil(groups["sif:whitehall"], "Whitehall doesn't merge with the Battery Maritime Building pier next door")
        }
        #else
        throw XCTSkip("ZIP needs macOS Compression")
        #endif
    }
}

extension FerryFeed.Coverage {
    /// For tests: encode and decode once (what's stored in UserDefaults is JSON)
    static func decodeRoundTrip(_ c: FerryFeed.Coverage) throws -> FerryFeed.Coverage {
        try JSONDecoder().decode(FerryFeed.Coverage.self, from: JSONEncoder().encode(c))
    }
}

/// The order of turns in testLargePackagesOneAtATime
private actor TurnLog {
    var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

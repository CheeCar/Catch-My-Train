import Foundation

extension RegionalBusFeed {
    /// All agencies in code (display order). The 511NY ones use its public copy on S3 (Westchester County's own site refuses downloads).
    public static let builtIn: [RegionalBusFeed] = [
        njTransit,
        .init(code: "NICE", name: "NICE", url: "https://www.nicebus.com/NICE/media/nicebus-gtfs/NICE_GTFS.zip", color: "00539B"),
        // Realtime: Suffolk County provides it via Swiftly; you must fill out a request form to get your own key (it returns 401 without a key;
        // the county's old gtfsrealtime.suffolkcountyny.gov is just a maintenance page). The timetable comes from tracksctbus.org (the one on the county site stops in 2025).
        .init(code: "SCT", name: "Suffolk County Transit", url: "https://tracksctbus.org/gtfs", color: "1F5F3A",
              keyedRealtime: "https://api.goswift.ly/real-time/suffolk-county/gtfs-rt-trip-updates"),
        // Realtime: the trip updates on Westchester County's own server (free, no key; its trip and route IDs are the same as in
        // 511NY's copy of the timetable). Its earlier address at ITO World has answered only 503 (temporarily unavailable) for weeks.
        // The timetable comes from 511NY's copy (the county's own site refuses downloads).
        .init(code: "BXL", name: "Bee-Line", url: "https://s3.amazonaws.com/datatools-511ny/public/Westchester_County_Bee-Line_System.zip",
              color: "0080C0", realtime: "https://westchester.gmv.com/gtfsrtapi/api/tripupdates"),
        .init(code: "HL", name: "Hudson Link", url: "https://data.trilliumtransit.com/gtfs/hudsonlink-ny-us/hudsonlink-ny-us.zip",
              color: "005DAA"),
        .init(code: "CMT", name: "Clarkstown Mini-Trans", url: "https://s3.amazonaws.com/datatools-511ny/public/Clarkstown_Mini_Trans.zip",
              color: "4C4AE2"),
        .init(code: "PART", name: "Putnam Transit", url: "https://s3.amazonaws.com/datatools-511ny/public/PART_Putnam_Area_Rapid_Transit.zip",
              color: "3758C7"),
        .init(code: "DCT", name: "Dutchess County Public Transit", url: "https://s3.amazonaws.com/datatools-511ny/public/Dutchess_County_Transit.zip",
              color: "0051A0"),
        .init(code: "LEP", name: "Leprechaun Lines", url: "https://s3.amazonaws.com/datatools-511ny/public/Leprechaun_Connection.zip",
              color: "2E8B22"),
        .init(code: "HART", name: "Huntington HART", url: "https://s3.amazonaws.com/datatools-511ny/public/HART_Huntington_Area_Rapid_Transit.zip",
              color: "0023FF"),
        .init(code: "LB", name: "Long Beach Bus", url: "https://s3.amazonaws.com/datatools-511ny/public/City_of_Long_Beach.zip",
              color: "0A6FB5"),
        // Realtime: GTFS-Realtime from the developer page on CTtransit's website (free, no key)
        .init(code: "CTT", name: "CTtransit", url: "https://www.cttransit.com/sites/default/files/gtfs/googlect_transit.zip",
              color: "005BAA", onlyServiceArea: true,
              realtime: "https://cttprdtmgtfs.ctttrpcloud.com/TMGTFSRealTimeWebService/TripUpdate/TripUpdates.pb", readingVersion: 1),
        .init(code: "GBT", name: "Greater Bridgeport Transit", url: "https://data.trilliumtransit.com/gtfs/gbt-ct-us/gbt-ct-us.zip",
              color: "E31837"),
        // From here on the color is the most common route color in each operator's own data that white text can be read on
        // (4.5:1 or more, not gray); none of these has live data. Ulster's data splits lines by direction and has internal
        // headsigns, Sullivan's has no headsigns or directions: see NJBusBuilder
        .init(code: "UCAT", name: "Ulster County Area Transit",
              url: "https://s3.amazonaws.com/datatools-511ny/public/UCAT_Ulster_County_Area_Transit.zip", color: "974806"),
        .init(code: "SUL", name: "Sullivan County Transit", url: "https://s3.amazonaws.com/datatools-511ny/public/Sullivan_County.zip",
              color: "2B4D0D"),
        // The operator's own site (InfoPoint); its older link refuses downloads
        .init(code: "NTD", name: "Norwalk Transit District", url: "https://mystop.norwalktransit.com/InfoPoint/gtfs-zip.ashx",
              color: "B62025", headsignsNameRoutes: true),
        // Still filed under its former name (9 Town Transit) at Trillium
        .init(code: "RVT", name: "River Valley Transit",
              url: "https://data.trilliumtransit.com/gtfs/ninetown-connecticut-us/ninetown-connecticut-us.zip", color: "2F541D",
              headsignsNameRoutes: true),
        .init(code: "SEAT", name: "Southeast Area Transit", url: "https://gtfs.remix.com/seat_preston_ct_us.zip", color: "5568D9"),
        // The coaches from New Jersey and the Hudson Valley to Manhattan and the county buses of northern and central New Jersey,
        // timetables only, each downloaded only for places near its own stops (its own DownloadArea; Manhattan's too for those
        // that stop at Port Authority Bus Terminal). Colors as for Ulster's on; the ones whose data has none, or none white text
        // can be read on, a dark one of their own. Coach USA's six companies around New York share one package with four
        // elsewhere in the country: each reads only its own part (agency), one download serves the six (downloadOrder), and its
        // short route names are the company's name, the routes' numbers starting their long names (shortNamesNameCompany)
        .init(code: "SLH", name: "ShortLine Hudson", url: Self.coachUSA, color: "B04876",
              lineColors: ["00-10": "AC61A7", "20-30": "D649A4", "100": "64AD45", "200": "ED60A3", "250": "00ADE2", "300": "8A91DC",
                           "400": "ED105B", "500": "8387C1", "600": "008C84", "700": "EF5059", "800": "EC3159", "900": "AB2B53",
                           "Eastside": "B04876", "Main Line": "FF6442"],
              agency: .init(id: "1574", name: "ShortLine Hudson"), shortNamesNameCompany: true,
              badgesByLongName: ["Eastside Woodbury Common": "Eastside", "Eastside Manhattan Commuter Service": "Eastside"],
              downloadArea: .shortLine),
        .init(code: "SUBT", name: "Suburban Transit", url: Self.coachUSA, color: "1B5E8C",
              agency: .init(id: "1573", name: "Suburban Transit"), shortNamesNameCompany: true, downloadArea: .suburbanTransit),
        .init(code: "ROCK", name: "Rockland Coaches", url: Self.coachUSA, color: "2E7D32",
              agency: .init(id: "1559", name: "Rockland Coaches"), shortNamesNameCompany: true, downloadArea: .rocklandCoaches),
        .init(code: "COMC", name: "Community Coach", url: Self.coachUSA, color: "5D3A9B",
              agency: .init(id: "1566", name: "Community Coach"), shortNamesNameCompany: true, downloadArea: .communityCoach),
        // From Newark Airport's terminals to Port Authority Bus Terminal and Grand Central: one route, by the airport's code
        .init(code: "NAE", name: "Newark Airport Express", url: Self.coachUSA, color: "C62828",
              agency: .init(id: "664", name: "Newark Airport Express"), shortNamesNameCompany: true,
              badgesByLongName: ["Newark Airport Express": "EWR"], downloadArea: .newarkAirportExpress),
        // From Middletown to White Plains, by the name its riders know it by
        .init(code: "OWL", name: "Orange Westchester Link", url: Self.coachUSA, color: "3A5A78", lineColors: ["OWL": "CCDBE9"],
              agency: .init(id: "1801", name: "Orange Westchester Link"), shortNamesNameCompany: true,
              badgesByLongName: ["Orange Westchester Link": "OWL"], downloadArea: .orangeWestchester),
        // Published on NJ Transit's website, like the county shuttles of South Jersey. Lakeland's routes have no short names, a
        // route for each way ("Rt. 46/80 - Eastbound"): each pair is one, by its highway or where it goes
        .init(code: "LAKE", name: "Lakeland Bus Lines", url: Self.njTransitSite + "LakelandBusLines_bus_data.zip", color: "7A4419",
              badgesByLongNameStart: ["Rt. 46/80": "46/80", "Rt. 78": "78", "Downtown Wall Street": "Wall St"],
              downloadArea: .lakeland),
        // Its data gives every trip direction 1
        .init(code: "HUNT", name: "Hunterdon County LINK", url: Self.njTransitSite + "Hunterdon_Co_bus_data.zip", color: "002294",
              lineColors: ["14": "00AFEF", "15": "FF0000", "16": "002294", "17": "FF3298", "18": "007F00", "19": "FFBF00",
                           "21": "006500", "23": "7F007F"],
              directionsFromStops: true, downloadArea: .hunterdon),
        // Its headsigns describe the route with the place ("Route 36 to Port Authority - Highlands Highway"), so each trip's
        // terminal is shown instead. Its data colors nearly every route black
        .init(code: "ACAD", name: "Academy Bus", url: Self.njTransitSite + "Academy_bus_data.zip", color: "A31F34",
              headsignsNameRoutes: true, downloadArea: .academy),
        .init(code: "SOM", name: "Somerset County Transportation", url: Self.njTransitSite + "SomersetCounty_bus_data.zip",
              color: "4E5B9C", downloadArea: .somerset),
        .init(code: "SUSX", name: "Sussex County Skylands Ride", url: Self.njTransitSite + "sussexcounty_bus_data.zip",
              color: "8E3A9A", lineColors: ["Skylands": "D670DA", "New Freedom": "ED9564"],
              badgesByLongName: ["Skylands Connect": "Skylands"], downloadArea: .sussex),
        // Philadelphia: SEPTA's buses and trackless trolleys, in the same package as its Metro (see FerryFeed.Source.septaMetro), with
        // free live data for both (no key). Its data colors nearly every route white or black: SEPTA's own blue instead. The package
        // is large, so it's downloaded only for places in its area
        .init(code: RegionalBusFeed.septaCode, name: "SEPTA", url: FerryFeed.septaBusURL.absoluteString, color: "104E8B",
              realtime: FerryFeed.septaBusRealtimeURL.absoluteString, downloadArea: .philadelphia),
        // Philadelphia: PHLASH, the visitor loop buses, published by the Philadelphia Visitors Center Corporation on GitHub for transit
        // and map apps. Timetable only, and small, so it's downloaded for everyone. It runs in season: between seasons its data has
        // no trips, Settings says there's no current timetable and the app checks daily (as for the Statue of Liberty ferry)
        .init(code: "PHLASH", name: "PHLASH", url: "https://github.com/PhlashGTFS/GTFS/releases/latest/download/PHLASH_GTFS.zip",
              color: "4D3E98", routeNamePrefix: "PHLASH "),
        // The rest of the Philadelphia metro area in Pennsylvania and Maryland: small packages, each downloaded only for places in
        // its area. Pottstown's code isn't "PART" (Putnam's). Pottstown's, BARTA's and Cecil Transit's live data is free (no key)
        .init(code: "POTT", name: "Pottstown Area Rapid Transit", url: "https://part.rideralerts.com/InfoPoint/gtfs-zip.ashx",
              color: "1F5DA8", realtime: "https://part.rideralerts.com/InfoPoint/GTFS-Realtime.ashx?Type=TripUpdate",
              downloadArea: .philadelphia),
        // SCCOOT and Coatesville LINK, published through Modeshift (its ticket app); no live data
        .init(code: "TMACC", name: "TMACC ChescoBus", url: "https://www.modeshift.app/api/v1/0045359e-7cae-4a10-b680-cafe365c6554/transport/gtfs/gtfs.zip",
              color: "B80000", downloadArea: .chesterAndCecil),
        // King of Prussia's shuttle, hosted by National RTAP; no live data
        .init(code: "UMR", name: "Upper Merion Rambler",
              url: "https://rapid.nationalrtap.org/GTFSFileManagement/UserUploadFiles/13641/UPPER_MERION_RAMBLER.zip",
              color: "1F6F43", downloadArea: .philadelphia),
        // Reading and Berks County
        .init(code: "BARTA", name: "BARTA", url: "https://busfinder.bartabus.com/InfoPoint/gtfs-zip.ashx", color: "AA00FF",
              realtime: "https://busfinder.bartabus.com/InfoPoint/GTFS-Realtime.ashx?Type=TripUpdate", downloadArea: .reading),
        // Cecil County, MD: Passio's copy (the county's own runs out sooner), with its live data
        .init(code: "CECIL", name: "Cecil Transit", url: "https://passio3.com/cecil/passioTransit/gtfs/google_transit.zip",
              color: "214089", realtime: "https://passio3.com/cecil/passioTransit/gtfs/realtime/tripUpdates",
              downloadArea: .chesterAndCecil),
        // South Jersey's county shuttles and SJTA, all published on NJ Transit's website, timetable only, downloaded only for
        // places in South Jersey. BurLINK's data has no short route names: its badges are the codes in the long names ("B1").
        // Atlantic County's and SJTA's headsigns repeat the route's name. Gloucester's and Cumberland's data have no colors
        .init(code: "BURL", name: "BurLINK", url: Self.njTransitSite + "BurlingtonShuttles_bus_data.zip", color: "703895",
              routeNamePrefix: "BurLINK ", downloadArea: .southJersey),
        .init(code: "GLOU", name: "Gloucester County Shuttle", url: Self.njTransitSite + "Gloucester_Co_bus_data.zip",
              color: "2E6B8A", downloadArea: .southJersey),
        .init(code: "ATLC", name: "Atlantic County Shuttles", url: Self.njTransitSite + "AtlanticCo_bus_data.zip", color: "1F497D",
              headsignsNameRoutes: true, downloadArea: .southJersey),
        .init(code: "CUMB", name: "Cumberland County Shuttles", url: Self.njTransitSite + "Cumberland_Co_bus_data.zip",
              color: "8B2A2A", downloadArea: .southJersey),
        .init(code: "SJTA", name: "SJTA", url: Self.njTransitSite + "SJTA_bus_data.zip", color: "8064A2", headsignsNameRoutes: true,
              downloadArea: .southJersey),
        // The Lehigh Valley: LANta (Allentown, Bethlehem, Easton and Carbon County) and the Pocono Pony (Monroe County), both on the
        // operators' own InfoPoint servers with free live data (no key), and Warren County's shuttles, published on NJ Transit's
        // website, timetable only; each downloaded only for places in the Lehigh Valley. The Pocono Pony's routes each have their own
        // color: the color is its first route's that white text can be read on. Warren County's data has no colors
        .init(code: "LANTA", name: "LANta", url: "https://realtimelanta.availtec.com/InfoPoint/GTFS-Zip.ashx", color: "00447C",
              realtime: "https://realtimelanta.availtec.com/InfoPoint/GTFS-Realtime.ashx?Type=TripUpdate", downloadArea: .lehighValley),
        .init(code: "PONY", name: "Pocono Pony", url: "https://ponytracker.availtec.com/InfoPoint/gtfs-zip.ashx", color: "337AB7",
              realtime: "https://ponytracker.availtec.com/InfoPoint/gtfs-realtime.ashx?type=tripupdate", downloadArea: .lehighValley),
        .init(code: "WARR", name: "Warren County Transportation", url: Self.njTransitSite + "WCT_bus_data.zip", color: "2F6B3A",
              downloadArea: .lehighValley),
        // Trans-Bridge Lines, the coaches from Allentown, Bethlehem, Easton and Doylestown to New York (Port Authority, Wall Street) and
        // Newark Airport, published on NJ Transit's website, timetable only. It stops in three metro areas, so it's downloaded for
        // everyone. Its data has a route per trip and no short names ("Allentown-Clinton Eastbound"): see routesByFirstPlace. No colors
        .init(code: "TBL", name: "Trans-Bridge Lines", url: Self.njTransitSite + "Trans-Bridge_bus_data.zip", color: "B22234",
              routesByFirstPlace: true),
        // Greater Boston: the MBTA's buses, the Silver Line among them (its badges say SL1 to SL5 and SLW), in one package with its
        // subway, trains and ferries (see FerryFeed.Source.mbtaSubway), with free live data for all of them (no key). Its data colors
        // the buses yellow, which white text can't be read on: a dark blue instead. The package is large, so it's downloaded only for
        // places in Greater Boston
        .init(code: RegionalBusFeed.mbtaCode, name: "MBTA", url: FerryFeed.mbtaURL.absoluteString, color: "165C96",
              badgesByDescription: ["Rail Replacement Bus": "Shuttle"], realtime: FerryFeed.mbtaRealtimeURL.absoluteString,
              downloadArea: .greaterBoston),
        // Around Greater Boston: the regional transit authorities of Massachusetts and Rhode Island, Massport's Logan Express and
        // the buses of southern New Hampshire, each downloaded only for places near its own stops (its own DownloadArea). Free live
        // data (no key) from WRTA, LRTA and GATRA (one server, cadavl) and from BAT and COAST (Passio, like Cecil Transit). RIPTA's
        // live data is only on plain http, which the app doesn't use, and MeVa's needs a Swiftly key: timetables only. Colors are
        // each one's first route color that white text can be read on; SRTA's data colors every route white, so a dark blue instead
        // RIPTA's timetable at the address its short one (ripta.com/RIPTA-GTFS.zip) sends to over plain http, which the app doesn't
        // follow: the same file, over https
        .init(code: "RIPTA", name: "RIPTA", url: "https://ripta.com/system/files/gtfs_file/RIPTA-GTFS.zip", color: "E0004D",
              downloadArea: .rhodeIsland),
        .init(code: "WRTA", name: "WRTA", url: "https://gtfs.wrta.cadavl.com/WRTA/GTFS/GTFS_WRTA.zip", color: "3100FF",
              realtime: "https://gtfsrt.wrta.cadavl.com/ProfilGtfsRt2_0RSProducer-WRTA/TripUpdate.pb", downloadArea: .worcester),
        .init(code: "LRTA", name: "LRTA", url: "https://gtfs.lrta.cadavl.com/LRTA/GTFS/GTFS_LRTA.zip", color: "444582",
              realtime: "https://gtfsrt.lrta.cadavl.com/ProfilGtfsRt2_0RSProducer-LRTA/TripUpdate.pb", downloadArea: .lowell),
        .init(code: "GATRA", name: "GATRA", url: "https://gtfs.gatra.cadavl.com/GATRA/GTFS/GTFS_GATRA.zip", color: "D3312C",
              realtime: "https://gtfsrt.gatra.cadavl.com/ProfilGtfsRt2_0RSProducer-GATRA/TripUpdate.pb", downloadArea: .attleboroAndTaunton),
        .init(code: "SRTA", name: "SRTA", url: Self.trillium + "srta-ma-us/srta-ma-us.zip", color: "1B4F8A",
              downloadArea: .fallRiverAndNewBedford),
        .init(code: "BAT", name: "BAT", url: "https://passio3.com/brockton/passioTransit/gtfs/google_transit.zip", color: "743299",
              realtime: "https://passio3.com/brockton/passioTransit/gtfs/realtime/tripUpdates", downloadArea: .brockton),
        // Cape Cod's routes have no short names, and two long names start with Hyannis
        .init(code: "CCRTA", name: "CCRTA", url: Self.trillium + "capecod-ma-us/capecod-ma-us.zip", color: "005CAA",
              badgesByLongName: ["Sealine Hyannis-Falmouth/Woods Hole": "Sealine", "H2O Hyannis-Orleans": "H2O",
                                 "Hyannis Area Trolley": "Trolley", "CapeFLYER Connection": "CapeFLYER", "Barnstable Villager": "Villager",
                                 "Hyannis Crosstown": "Crosstown", "Sandwich Line": "Sandwich", "Bourne Run": "Bourne",
                                 "Patriot LTD": "Patriot", "WHOOSH Trolley": "WHOOSH", "Provincetown/North Truro Shuttle": "Shuttle"],
              downloadArea: .capeCod),
        // Montachusett's numbered routes have short names; its shuttles and Gardner's routes don't
        .init(code: "MART", name: "MART", url: Self.trillium + "montachusett-ma-us/montachusett-ma-us.zip", color: "CC0000",
              badgesByLongName: ["Athol/Orange Shuttle": "Athol", "Gardner Route 1": "G1", "Gardner Route 2": "G2", "Gardner Route 3": "G3",
                                 "GLink: Gardner/Athol": "GLink", "GLink: Gardner to Winchendon": "GLink",
                                 "GLink: Winchendon to Gardner": "GLink", "Boston Shuttle": "Boston",
                                 "Clinton-Worcester Commuter Shuttle": "Clinton", "Harvard Commuter Shuttle": "Harvard",
                                 "Wachusett Commuter Shuttle": "Wachusett", "Emerson Hospital Shuttle": "Emerson"],
              downloadArea: .montachusett),
        .init(code: "MEVA", name: "MeVa Transit", url: Self.trillium + "merrimackvalley-ma-us/merrimackvalley-ma-us.zip", color: "A82555",
              badgesByLongName: ["30 Amesbury Town Park": "30"], downloadArea: .merrimackValley),
        .init(code: "CATA", name: "CATA", url: Self.trillium + "capeann-ma-us/capeann-ma-us.zip", color: "964B00", downloadArea: .capeAnn),
        .init(code: "MWRTA", name: "MWRTA", url: "https://vc.mwrta.com/gtfs/google_transit.zip", color: "DC143C", routeNamePrefix: "RT",
              downloadArea: .metroWest),
        .init(code: "LOGAN", name: "Massport", url: Self.trillium + "massport-ma-us/massport-ma-us.zip", color: "0E3475",
              downloadArea: .loganExpress),
        // Manchester's long names start with the route number ("1 Dartmouth/VA Hospital", "2S Hanover St…")
        .init(code: "MANCH", name: "Manchester Transit Authority",
              url: "https://rapid.nationalrtap.org/GTFSFileManagement/UserUploadFiles/7841/NHMTAGTFS.zip", color: "833C0B",
              badgesByLongName: ["Salem Shopper Shuttle": "Shopper"], downloadArea: .manchester),
        .init(code: "NTS", name: "Nashua Transit System",
              url: "https://rapid.nationalrtap.org/GTFSFileManagement/UserUploadFiles/11685/Nashua_Transit_System_GTFS.zip",
              color: "B62000", downloadArea: .nashua),
        // The Seacoast of New Hampshire, with stops in Maine (Berwick, South Berwick, Eliot, Kittery)
        .init(code: "COAST", name: "COAST", url: "https://passio3.com/COAST/passioTransit/gtfs/google_transit.zip", color: "144069",
              realtime: "https://passio3.com/COAST/passioTransit/gtfs/realtime/tripUpdates", downloadArea: .seacoast),
        // The islands' buses, timetables only (no live data published without a key): Martha's Vineyard's VTA and Nantucket's
        // WAVE. The WAVE's routes have no short names and three of their long names start with Sconset: each by the road it takes
        .init(code: "VTA", name: "VTA", url: Self.trillium + "marthasvineyard-ma-us/marthasvineyard-ma-us.zip", color: "D2000A",
              downloadArea: .marthasVineyard),
        .init(code: "NRTA", name: "The WAVE", url: Self.trillium + "nantucket-ma-us/nantucket-ma-us.zip", color: "007141",
              badgesByLongName: ["Madaket Route": "Madaket", "Sconset via Milestone Road Route": "Milestone",
                                 "Sconset via Old South Road Route": "Old South", "Sconset via Polpis Road Route": "Polpis",
                                 "Airport": "Airport", "Jetties Beach Route": "Jetties", "Miacomet Loop": "Miacomet",
                                 "Mid Island Loop": "Mid Island"],
              downloadArea: .nantucket),
        // Greater Hartford and Western Massachusetts, where CTtransit, the Hartford Line and Amtrak run too: the regional transit
        // authorities of western Massachusetts and the transit districts of eastern and northwestern Connecticut, each downloaded
        // only for places near its own stops (its own DownloadArea). Free live data (no key) from PVTA, on its own InfoPoint server
        // like LANta's, and from FRTA and WRTD, on Passio's like BAT's. Colors are each one's most common route color that white
        // text can be read on, the first such one where none repeats (BRTA's from its own routes, not Link413's; FRTA's from
        // Trillium's copy of its data); WRTD's is a dark blue of its own, its data giving each line its own color
        // PVTA's live data names trips by block and first departure (tripsByBlock), not as its timetable does; its timetable has the
        // Link413's 904 too, which BRTA's has as well: left out here
        .init(code: "PVTA", name: "PVTA", url: "https://www.pvta.com/g_trans/google_transit.zip", color: "00467E",
              leftOutRoutes: ["904"], realtime: "https://bustracker.pvta.com/infopoint/GTFS-Realtime.ashx?Type=TripUpdate",
              tripsByBlock: true, downloadArea: .pioneerValley, readingVersion: 1),
        // Trillium's copy of FRTA's timetable, whose stops its live data (on Passio's server) names. The live data's trip IDs are
        // in no copy: some are the numbers of Passio's copy, others an old Trillium copy's, so its trips go by stops and time
        .init(code: "FRTA", name: "FRTA", url: Self.trillium + "frta-ma-us/frta-ma-us.zip", color: "375623",
              realtime: "https://passio3.com/frta/passioTransit/gtfs/realtime/tripUpdates", liveByStopsAndTime: true,
              downloadArea: .franklinCounty, readingVersion: 2),
        // With the Link413 buses (901, 903, 904) from Pittsfield and North Adams to Greenfield and Northampton
        .init(code: "BRTA", name: "BRTA", url: Self.trillium + "berkshire-ma-us/berkshire-ma-us.zip", color: "9400D3",
              downloadArea: .berkshires),
        // Its routes' short names are colors; one is a whole name. Published through Arcadis, like NWCTD's
        // Each line in its own color (its data's route_color): the lines are known by them
        .init(code: "NECTD", name: "NECTD", url: "https://hosted-gtfs-feeds.s3.amazonaws.com/NECTD/gtfs.zip", color: "417505",
              lineColors: ["Blue": "4A90E2", "Green": "417505", "Orange": "F5A623", "Weekender": "F8E71C", "Red-Purple": "DD3355"],
              badgesByLongName: ["Red-Purple Shuttle": "Red-Purple"], downloadArea: .northeasternConnecticut, readingVersion: 1),
        // The University of Connecticut's copy on Passio, with its live data: WRTD's buses in and from Willimantic and the campus
        // buses WRTD runs at the university in Storrs. Four campus routes have no short names, and their long names end with the
        // term ("Purple A Fall 2026"). Each line in its own color (its data's route_color), but 674D and 674E, whose routes
        // (trips at the start and end of a term) have several
        .init(code: "WRTD", name: "WRTD", url: "https://passio3.com/uconn/passioTransit/gtfs/google_transit.zip", color: "2B4C7E",
              lineColors: ["671A": "6E1D14", "671B": "EB650F", "675": "FF1493", "676": "E377C2", "674A": "1F77B4", "674B": "32B1CD",
                           "674C": "4D84D6", "991": "9D0909", "993": "177D3C", "Blue A": "3C42FF", "Blue B": "1F77B4",
                           "CL1": "009999", "CL2": "FF6699", "Purple A": "6D409D", "Purple B": "7239AB", "Red": "D62728",
                           "Yellow A": "FAEB34", "Yellow B": "E7BA52"],
              badgesByLongNameStart: ["Purple A": "Purple A", "Purple B": "Purple B", "Yellow Line A": "Yellow A",
                                      "Yellow Line B": "Yellow B"],
              realtime: "https://passio3.com/uconn/passioTransit/gtfs/realtime/tripUpdates", downloadArea: .windham,
              readingVersion: 2),
        // Two routes have no short names: Torrington's Saturday route and the Job Access bus
        // Each line in its own color too (its data's route_color)
        .init(code: "NWCTD", name: "NWCTD", url: "https://hosted-gtfs-feeds.s3.amazonaws.com/NWCTD/gtfs.zip", color: "146515",
              lineColors: ["1": "ED618E", "1B": "12A5EA", "3": "A7F5A5", "5": "146515", "Sat": "034107", "Job Access": "2FD0E4"],
              badgesByLongName: ["Saturday Torrington": "Sat", "Job Access AM/PM": "Job Access"], downloadArea: .northwestHills,
              readingVersion: 1),
    ]
}

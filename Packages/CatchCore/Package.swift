// swift-tools-version:5.9
// CatchCore: pure logic module independent of the UI (depends only on Foundation),
// usable by the main app/widget in Xcode, and testable on its own with `swift test`.
import PackageDescription

let package = Package(
    name: "CatchCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TransitCore", targets: ["TransitCore"]),
        .library(name: "CatchText", targets: ["CatchText"]),
    ],
    targets: [
        // Data generated from MTA static GTFS by the scripts in tools/:
        // subway_stations.json (stations), subway_map.json (subway map), express_stops.json (express / local),
        // bus_stops.json (bus stops and routes), bus_map.json (bus map).
        // source-list.json: where each operator's data is downloaded from, and the stations without times (see SourceList).
        // water.bin: the large water areas (US Census Bureau TIGER/Line, public domain), made by tools/generate_water.py (see WaterMap).
        // areas.json: the metro areas, their regions and counties; area_counties.bin: those counties' outlines (US Census Bureau,
        // public domain), made by tools/generate_areas.py (see AreaCatalog, CountyMap).
        // Listed one by one: Xcode may not notice new files added to a folder; listing them makes the manifest change so it rereads.
        .target(name: "TransitCore", resources: [
            .copy("Resources/subway_stations.json"),
            .copy("Resources/subway_map.json"),
            .copy("Resources/express_stops.json"),
            .copy("Resources/bus_stops.json"),
            .copy("Resources/bus_map.json"),
            .copy("Resources/source-list.json"),
            .copy("Resources/water.bin"),
            .copy("Resources/areas.json"),
            .copy("Resources/area_counties.bin"),
        ]),
        // UI text: translations, time and distance formatting (meters / feet)
        // The translation tables live in Resources as JSON (one file per language) so the Swift source is English only.
        // date_names.json: month and weekday names for languages whose locale has no date data (Haitian Creole).
        // language_names_extra.json: the names of languages in the languages the Mac has none or not all in (LanguageList).
        .target(name: "CatchText", dependencies: ["TransitCore"], resources: [
            .copy("Resources/language_names.json"),
            .copy("Resources/date_names.json"),
            .copy("Resources/language_names_extra.json"),
            .copy("Resources/translations"),
        ]),
        .testTarget(name: "TransitCoreTests", dependencies: ["TransitCore"]),
        .testTarget(name: "CatchTextTests", dependencies: ["CatchText", "TransitCore"]),
    ]
)

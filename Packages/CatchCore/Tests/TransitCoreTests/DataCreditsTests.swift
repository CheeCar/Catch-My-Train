import XCTest
@testable import TransitCore

/// Every data source must be credited everywhere data is described.
final class DataCreditsTests: XCTestCase {
    private var credits: String { DataCredits.downloaded.joined(separator: ", ") }

    func testEveryBusFeedIsCredited() {
        for feed in RegionalBusFeed.all {
            XCTAssertTrue(credits.contains(feed.name), "\(feed.name) is missing from DataCredits.downloaded")
        }
    }

    func testEveryRailAndFerrySourceIsCredited() {
        for source in FerryFeed.Source.allCases {
            XCTAssertTrue(credits.contains(source.shortName), "\(source.shortName) is missing from DataCredits.downloaded")
        }
        XCTAssertTrue(credits.contains("RIOC"), "the Roosevelt Island Tram operator is missing")
        // A line of its own, though its timetable comes in Amtrak's package
        XCTAssertTrue(credits.contains(FerryFeed.shoreLineEast.name), "Shore Line East is missing from DataCredits.downloaded")
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// README.md, or nil when the package is copied alone or the test host is sandboxed and can't read it
    private var readme: String? { try? String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8) }

    /// The metro areas' pages, as tools/generate_area_docs.py writes them from areas.json and tools/area-docs.json: each
    /// area in the app has its entry, its page and its link from README.md and docs/data-sources.md
    private func areaPages() throws -> [(id: String, name: String, page: String)] {
        let docs = root.appendingPathComponent("tools/area-docs.json")
        guard let data = try? Data(contentsOf: docs) else { throw XCTSkip("tools/area-docs.json can't be read here, skipping") }
        struct File: Decodable { struct Area: Decodable { let id: String; let slug: String }; let areas: [Area] }
        let file = try JSONDecoder().decode(File.self, from: data)
        XCTAssertEqual(file.areas.map(\.id), AreaCatalog.shared.areas.map(\.id), "tools/area-docs.json must list areas.json's metro areas, in order")
        return try file.areas.map { area in
            let url = root.appendingPathComponent("docs/data-sources/\(area.slug).md")
            let page = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8), "docs/data-sources/\(area.slug).md is missing: run tools/generate_area_docs.py")
            return (area.slug, AreaCatalog.shared.area(area.id)?.name ?? area.id, page)
        }
    }

    func testEveryAreaHasItsPage() throws {
        guard let text = readme else { throw XCTSkip("README.md can't be read here, skipping") }
        let index = try XCTUnwrap(try? String(contentsOf: root.appendingPathComponent("docs/data-sources.md"), encoding: .utf8))
        // README.md names no area (so it stays short however many there are): it links Data sources, which links every area's page
        XCTAssertTrue(text.contains("[Data sources](docs/data-sources.md)"), "README.md's service area must link docs/data-sources.md")
        for area in try areaPages() {
            XCTAssertTrue(area.page.contains("# \(area.name)\n"), "docs/data-sources/\(area.id).md must be about \(area.name)")
            XCTAssertTrue(index.contains("[\(area.name)](data-sources/\(area.id).md)"), "docs/data-sources.md must link \(area.name)'s page")
        }
        for tag in ["intro", "service-area"] {
            XCTAssertTrue(text.contains("<!-- generated:\(tag) -->") && text.contains("<!-- /generated:\(tag) -->"), "README.md lost its \(tag) markers")
        }
        XCTAssertFalse(text.contains("New York and Philadelphia Metropolitan Areas"), "README.md names the areas outside its generated parts")
    }

    /// The data sources pages must name the same operators as the app; README.md links them.
    func testRepositoryPagesNameEveryOperator() throws {
        guard let text = readme else { throw XCTSkip("README.md can't be read here, skipping") }
        XCTAssertTrue(text.contains("](docs/data-sources.md)"), "README.md must link the full list in docs/data-sources.md")
        let index = try XCTUnwrap(try? String(contentsOf: root.appendingPathComponent("docs/data-sources.md"), encoding: .utf8),
                                  "docs/data-sources.md is missing")
        let pages = try areaPages().map(\.page)
        let sources = ([index] + pages).joined(separator: "\n")
        for name in DataCredits.downloaded.map(Self.operatorName) + DataCredits.hosts {
            XCTAssertTrue(sources.contains(name), "the data sources pages don't credit \(name)")
        }
        XCTAssertTrue(sources.contains(FerryFeed.shoreLineEast.name), "the data sources pages don't name Shore Line East")
    }

    /// README.md describes the data in general words and links the full list (docs/data-sources.md and each area's page): a count
    /// of operators there ("… and 13 more") would have nothing to be checked against, so it isn't allowed
    func testReadmeCountsNoOperators() throws {
        guard let text = readme else { throw XCTSkip("README.md can't be read here, skipping") }
        let line = text.components(separatedBy: "\n").first { $0.range(of: "(,\\s*|\\s+)and [0-9]+ more\\b", options: .regularExpression) != nil }
        XCTAssertNil(line, "README.md counts operators: \(line?.prefix(120) ?? "")")
    }

    /// "NYC DOT (Staten Island Ferry)" → "NYC DOT": the data-sources page puts what each operator runs in its own column.
    static func operatorName(_ credit: String) -> String {
        credit.components(separatedBy: " (").first ?? credit
    }
}

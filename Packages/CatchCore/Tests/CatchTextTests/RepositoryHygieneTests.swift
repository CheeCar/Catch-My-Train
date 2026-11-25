import TransitCore
import XCTest

/// Checks that read the repository's own files: comments say what the code does and why, not when it changed; the project files
/// agree with each other and name no developer team; images carry no embedded metadata; and rules of the code that unit tests
/// can't see.
final class RepositoryHygieneTests: XCTestCase {
    /// Comments say what the code does and why, not when it changed (the history is in version control).
    /// Outside the tests no comment holds a date; in the tests a date may describe sample data
    /// ("2030-03-13 (Wednesday), noon in New York") but not when something was added ("(2030-03-15)", "2030-03-15: ...").
    /// wholeLine: prose (Markdown, plain text, LICENSE), where every line counts as comment.
    static func commentDates(in line: String, isTest: Bool, hashComments: Bool = false, markup: Bool = false, wholeLine: Bool = false) -> Bool {
        guard let comment = wholeLine ? line : commentPart(of: line, hashComments: hashComments, markup: markup) else { return false }
        let any = #"20\d\d-[01]\d-[0-3]\d"#
        let history = #"\(20\d\d-[01]\d-[0-3]\d[):;,]|^\W*20\d\d-[01]\d-[0-3]\d:|\b(?:on|since|added|changed|seen|found|measured) 20\d\d-[01]\d-[0-3]\d"#
        return comment.range(of: isTest ? history : any, options: .regularExpression) != nil
    }

    /// The comment on a line: after "//" (not inside "://"), in shell, Python and YAML files and dotfiles after a "#" that starts
    /// the line or follows a space, and with markup (HTML, property lists) after "<!--".
    static func commentPart(of line: String, hashComments: Bool, markup: Bool = false) -> String? {
        if markup, let r = line.range(of: "<!--") { return String(line[r.upperBound...]) }
        if let r = line.range(of: #"(?<![:"])//"#, options: .regularExpression) { return String(line[r.upperBound...]) }
        if hashComments, let r = line.range(of: #"(?:^|\s)#(?!!)"#, options: .regularExpression) { return String(line[r.upperBound...]) }
        return nil
    }

    /// A comment that tells change history (outside the tests): the version or month something changed in ("since 2.1.0",
    /// "seen in 1.9.0", "(2.0.0)", "the 1.10.0 bug", "in March 2030", "2030-07"), what the code used to do ("it used to wait",
    /// "previously"), the plan it was built in ("phase two", "first batch") or a one-off incident ("it once crashed").
    /// Quoted text is left out, so format examples pass ("e.g. \"2.1.0\"", "\"Mar 14, 2030\""), and so does purpose ("used to check").
    /// A comment about an upgrade or a migration may name the version it upgrades from.
    static func commentHistory(in line: String, hashComments: Bool, markup: Bool = false, wholeLine: Bool = false) -> Bool {
        guard let part = wholeLine ? line : commentPart(of: line, hashComments: hashComments, markup: markup) else { return false }
        let comment = part.replacingOccurrences(of: #""[^"]*"|“[^”]*”"#, with: "", options: .regularExpression)
        var patterns = [
            // A month with its year ("March 2030", "Feb 2031", "June 3, 2030"), or a year with its month ("2030-07")
            #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+(?:[0-3]?\d(?:st|nd|rd|th)?,?\s+)?20\d\d\b"#,
            #"\b20\d\d-[01]\d\b(?!-\d)"#,
            // What the code used to do; verbs that also say what something is for ("used to open", "used to record") aren't listed
            #"\b(?:it|they|there|each|both|we)\s+used to\b|\bused to (?:be|say|leave|occasionally|just)\b"#,
            #"\bpreviously\b(?!\s+(?:saved|downloaded|stored|chosen|shown|cached|received|read|entered|selected|picked|used))"#,
            // The plan it was built in, and one-off incidents
            #"\bphases?\s+(?:[0-9]|one|two|three|four)\b|\b(?:first|second|third) batch\b"#,
            #"\bonce (?:crashed|froze|showed|grew|hung)\b|\b(?:crashed|froze) once\b"#,
        ]
        if comment.range(of: #"upgrad|migrat"#, options: [.regularExpression, .caseInsensitive]) == nil {
            patterns.append(#"(?:\b(?:since|in|until|till|before|after|from|as of|up to)\s+|\(|\bthe\s+)v?[0-9]{1,2}\.[0-9]{1,3}\.[0-9]{1,3}(?![\w]|\.[0-9])"#)
        }
        return comment.range(of: patterns.joined(separator: "|"), options: [.regularExpression, .caseInsensitive]) != nil
    }

    func testHistoryPatterns() {
        func flagged(_ line: String, hash: Bool = false, markup: Bool = false, wholeLine: Bool = false) -> Bool {
            Self.commentHistory(in: line, hashComments: hash, markup: markup, wholeLine: wholeLine)
        }
        XCTAssertTrue(flagged("        // checks once a minute (since 2.1.0, to save power)"))
        XCTAssertTrue(flagged("    /// (seen in 1.9.0: the list opened empty)"))
        XCTAssertTrue(flagged("    // keeps the title on one line (the 1.10.0 bug)"))
        XCTAssertTrue(flagged("    /// Sorted by name first (2.0.0 change)"))
        XCTAssertTrue(flagged("    // Until 1.11.0 the button was hidden"))
        XCTAssertTrue(flagged("        // It used to be 3 tries"))
        XCTAssertTrue(flagged("    /// One copy for both pages (each used to keep its own)"))
        XCTAssertTrue(flagged("    /// (there used to be a second button)"))
        XCTAssertTrue(flagged("    /// Previously the list was sorted by date"))
        XCTAssertTrue(flagged("/// Only needed in phase two"))
        XCTAssertTrue(flagged("    /// First batch: the short names"))
        XCTAssertTrue(flagged("// the sale ended in March 2030"))
        XCTAssertTrue(flagged("        // valid through Feb 2031"))
        XCTAssertTrue(flagged("    /// match the 2030-07 list"))
        XCTAssertTrue(flagged("    /// Off while printing (it once crashed there)"))
        XCTAssertTrue(flagged("    // must wait for the window (froze once)"))
        XCTAssertTrue(flagged("# changed in 2.1.1", hash: true))
        XCTAssertTrue(flagged("    <!-- since 2.0.0 -->", markup: true))
        XCTAssertTrue(flagged("The icons were redrawn in 2.0.0.", wholeLine: true))

        XCTAssertFalse(flagged("    /// Station code, used to match when realtime data uses codes"))
        XCTAssertFalse(flagged("    /// The button (used to show the pressed state)"))
        XCTAssertFalse(flagged("    /// Only used to check whether the account works"))
        XCTAssertFalse(flagged("    /// The file used to record the log, and the key used to open the sheet"))
        XCTAssertFalse(flagged(#"    /// Date, e.g. "Mar 14, 2030""#))
        XCTAssertFalse(flagged(#"    /// Version number, e.g. "2.1.0""#))
        XCTAssertFalse(flagged(#"    /// Compared segment by segment: "2.0" == "2.0.0""#))
        XCTAssertFalse(flagged("    /// kept only to read previously saved settings"))
        XCTAssertFalse(flagged("    /// One-time upgrade of settings saved before 2.0.0 (the old default)"))
        XCTAssertFalse(flagged("    /// hide after 0.6 seconds"))
        XCTAssertFalse(flagged(#"let route = "M15+" // Select Bus Service"#))
        XCTAssertFalse(flagged("    // stop L03 at 40.761220, -73.964212"))
        XCTAssertFalse(flagged(#"    let url = "https://example.com/2030-03""#))
        XCTAssertFalse(flagged("    // 2020-2024 averages"))
        XCTAssertFalse(flagged("    <string>2.0.0</string>", markup: true))
        XCTAssertFalse(flagged("Plan a Trip uses live data when you leave within the next 30 minutes.", wholeLine: true))
    }

    func testDatePatterns() {
        XCTAssertTrue(Self.commentDates(in: "    // Keep the old list (2030-03-14)", isTest: false))
        XCTAssertTrue(Self.commentDates(in: "    /// This list expired 2030-06-01", isTest: false))
        XCTAssertTrue(Self.commentDates(in: "# Needs Python 3 (2030-03-14: no Python 2)", isTest: false, hashComments: true))
        XCTAssertFalse(Self.commentDates(in: #"    #if DEBUG"#, isTest: false))
        XCTAssertTrue(Self.commentDates(in: "    /// 2030-03-15: when the list changed", isTest: true))
        XCTAssertTrue(Self.commentDates(in: "    // checked (2030-03-18)", isTest: true))
        XCTAssertFalse(Self.commentDates(in: "    /// 2030-03-13 (Wednesday), noon in New York", isTest: true))
        XCTAssertFalse(Self.commentDates(in: "    /// this season runs 2030-05-01 to 2030-09-30", isTest: true))
        XCTAssertFalse(Self.commentDates(in: #"        let day = "2030-03-13" // a Wednesday"#, isTest: false))
        XCTAssertFalse(Self.commentDates(in: #"    let url = "https://example.com/2030-03-13""#, isTest: false))
        XCTAssertTrue(Self.commentDates(in: "    <!-- checked 2030-03-14 -->", isTest: false, markup: true))
        XCTAssertFalse(Self.commentDates(in: "    <string>2030-03-14</string>", isTest: false, markup: true))
        XCTAssertTrue(Self.commentDates(in: "This offer is valid until 2030-12-31.", isTest: false, wholeLine: true))
    }

    func testNoDatesInComments() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let skippedFolders: Set<String> = [".build", "build", ".git", ".swiftpm", "xcuserdata", "Resources", "translations",
                                           "node_modules", "DerivedData"]
        let codeExtensions: Set<String> = ["swift", "py", "sh", "mjs", "js", "yml", "yaml", "xcconfig"]
        // Comments after "<!--"; in prose every line counts, as in extensionless files (LICENSE)
        let markupExtensions: Set<String> = ["html", "plist", "xcprivacy", "entitlements"]
        let proseExtensions: Set<String> = ["md", "txt"]
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var checked = 0
        for case let url as URL in files {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skippedFolders.contains(url.lastPathComponent) { files.skipDescendants() }
                continue
            }
            let name = url.lastPathComponent
            // A dotfile (.gitignore) has no extension and "#" comments; Local.xcconfig.example is read as the xcconfig it stands for
            let isDotfile = name.hasPrefix(".")
            let ext = isDotfile ? "" : name.hasSuffix(".xcconfig.example") ? "xcconfig" : url.pathExtension
            let known = ext.isEmpty || codeExtensions.contains(ext) || markupExtensions.contains(ext) || proseExtensions.contains(ext)
            // This file spells out the patterns it looks for.
            guard known, name != "RepositoryHygieneTests.swift", name != ".DS_Store",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            let relative = url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.path + "/", with: "")
            let isTest = relative.hasPrefix("Packages/CatchCore/Tests/") || relative.hasPrefix("AppTests/")
            // Swift and xcconfig files comment with "//"
            let hash = isDotfile || (codeExtensions.contains(ext) && ext != "swift" && ext != "xcconfig")
            let markup = markupExtensions.contains(ext)
            let wholeLine = proseExtensions.contains(ext) || (ext.isEmpty && !isDotfile)
            for (number, part) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(part)
                let shown = line.trimmingCharacters(in: .whitespaces).prefix(120)
                if Self.commentDates(in: line, isTest: isTest, hashComments: hash, markup: markup, wholeLine: wholeLine) {
                    XCTFail("\(relative):\(number + 1) has a date in a comment: \(shown)")
                }
                if !isTest, Self.commentHistory(in: line, hashComments: hash, markup: markup, wholeLine: wholeLine) {
                    XCTFail("\(relative):\(number + 1) tells change history in a comment: \(shown)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 50, "found too few files; is the project root right?")
    }

    static let zoneName = try! NSRegularExpression(pattern: #""(Africa|America|Antarctica|Asia|Atlantic|Australia|Europe|Indian|Pacific|US|Etc)/[A-Za-z_+\-]+"|TimeZone\(abbreviation:|TimeZone\(secondsFromGMT: *-?[1-9]"#)

    func testZoneNamePattern() {
        func found(_ line: String) -> Bool { Self.zoneName.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
        XCTAssertTrue(found(#"f.timeZone = TimeZone(identifier: "America/New_York")"#))
        XCTAssertTrue(found(#"let zone = "Australia/Sydney""#))
        XCTAssertTrue(found(#"TimeZone(abbreviation: "EST")"#))
        XCTAssertTrue(found("TimeZone(secondsFromGMT: -18000)"))
        XCTAssertFalse(found("TimeZone(secondsFromGMT: 0)"))
        XCTAssertFalse(found("MetroArea.newYork.timeZone"))
        XCTAssertFalse(found(#"let name = "Greater Boston""#))
    }

    /// Every time zone comes from an area (Resources/areas.json), a timetable or the Mac, never from a name in the code: the app has
    /// four areas in one zone today, so a missed one would not show until an area in another zone is added.
    func testNoTimeZoneNamesInCode() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        var checked = 0
        for folder in ["App", "Widget", "Shared", "Packages/CatchCore/Sources"] {
            guard let files = fm.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                checked += 1
                for (number, part) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = String(part)
                    if Self.zoneName.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                        XCTFail("\(folder)/\(url.lastPathComponent):\(number + 1) names a time zone: \(line.trimmingCharacters(in: .whitespaces).prefix(120))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 50, "found too few files; is the project root right?")
    }

    /// Settings changes aren't saved while TransitModel.persistsSettings is off (in the tests' host, and while Demo mode reads the
    /// place settings again): every line of the TransitModel files that saves a setting checks the flag on that same line.
    func testEverySettingSaveChecksPersistsSettings() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        func codeLines(_ path: String) throws -> [String] {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0 }
        }
        // The model's own file and its extensions' (TransitModel+….swift): a setting can be saved from any of them
        let modelFiles = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("App/Services").path)
            .filter { $0.hasPrefix("TransitModel") && $0.hasSuffix(".swift") }.sorted()
        XCTAssertTrue(modelFiles.contains("TransitModel.swift"), "App/Services has no TransitModel.swift any more; update this test")
        let model = try modelFiles.flatMap { file in
            try codeLines("App/Services/" + file).enumerated().map { (file: file, number: $0.offset + 1, line: $0.element) }
        }
        let saves = ["SharedStore.language = language", "SharedStore.languageFollowsMac = languageFollowsMac", "Self.saveLayoutDirection(",
                     "SharedStore.units = units", "SharedStore.clock = clock",
                     "UserDefaults.standard.set(textSize.rawValue", "SharedStore.appearance = appearance", "SharedStore.system = system",
                     "SharedStore.locationMode = locationMode", "SharedStore.place = place", "SharedStore.saveSelection(",
                     "SharedStore.dataSource = dataSource", "SharedStore.catchSettings = settings",
                     "SharedStore.refreshIntervalSeconds = refreshInterval"]
        for save in saves {
            let found = model.filter { $0.line.contains(save) }
            XCTAssertFalse(found.isEmpty, "The TransitModel files have no \(save) any more; update this test")
            for (file, number, line) in found {
                let before = line.components(separatedBy: save)[0]
                XCTAssertTrue(before.contains("if persistsSettings {"), "\(file):\(number) saves a setting without checking persistsSettings on that line")
            }
        }
    }

    /// The same work for several items at once goes through Together, the only place in the app and its package where a task
    /// group is written, and that one hands nothing back: results handed back by a group can come back under the wrong item in an
    /// optimized build (see Together). Tests may use groups of their own
    func testTaskGroupsOnlyInTogether() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let group = try NSRegularExpression(pattern: #"\bwith(?:Throwing)?(?:Discarding)?TaskGroup\b|\b(?:Throwing)?(?:Discarding)?TaskGroup<"#)
        func uses(_ line: String) -> Bool {
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && group.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        XCTAssertTrue(uses("        await withTaskGroup(of: (String, Double?).self) { group in"))
        XCTAssertTrue(uses("        return try await withThrowingTaskGroup(of: Data.self) { group in"))
        XCTAssertTrue(uses("        await withDiscardingTaskGroup { group in"))
        XCTAssertTrue(uses("    func add(to group: inout TaskGroup<Int>) {"))
        XCTAssertFalse(uses("        // Not a withTaskGroup: see Together"))
        XCTAssertFalse(uses("        let answers = await Together.each(sources) { source -> FerryRealtime? in"))
        let home = "Packages/CatchCore/Sources/TransitCore/NetworkReach.swift"
        var checked = 0
        var atHome = 0
        for folder in ["App", "Shared", "Widget", "Packages/CatchCore/Sources"] {
            guard let files = fm.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let path = url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.path + "/", with: "")
                checked += 1
                let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                for (number, line) in lines.enumerated() where uses(String(line)) {
                    if path == home {
                        atHome += 1
                        XCTAssertTrue(line.contains("withTaskGroup(of: Void.self)"), "\(path):\(number + 1) Together's group must hand nothing back")
                    } else {
                        XCTFail("\(path):\(number + 1) writes a task group of its own; use Together.each")
                    }
                }
            }
        }
        XCTAssertEqual(atHome, 1, "Together's one group in \(home)")
        XCTAssertGreaterThan(checked, 50, "found too few Swift files; is the project root right?")
    }

    /// Everything is saved where every build can save: the program's own settings, and one plain folder the app and the widget
    /// share (SharedFolder). An App Group only works in a build signed with a developer team; a build without one is handed a
    /// path it can't save in, and loses everything when it quits. So no code reads or writes one, a settings store is opened by
    /// name in one place only (the program's own, SharedDefaults), and no entitlements file holds an App Group; both name
    /// the shared folder.
    func testNoAppGroupIsUsed() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        // Where each of these may be written, and on how many lines
        let allowed: [String: [String: Int]] = [
            "forSecurityApplicationGroupIdentifier": [:],
            "UserDefaults(suiteName:": ["Packages/CatchCore/Sources/TransitCore/NetworkReach.swift": 1],
        ]
        var found: [String: [String: Int]] = [:]
        var checked = 0
        for folder in ["App", "Shared", "Widget", "Packages/CatchCore/Sources"] {
            guard let files = fm.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let path = url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.path + "/", with: "")
                checked += 1
                let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                for line in lines where !line.hasPrefix("//") {
                    for word in allowed.keys where line.contains(word) {
                        found[word, default: [:]][path, default: 0] += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 50, "found too few Swift files; is the project root right?")
        for (word, places) in allowed {
            XCTAssertEqual(found[word] ?? [:], places, "\(word) belongs only where a program opens its own settings")
        }
        // The entitlements
        let groups = "com.apple.security.application-groups"
        func entitlements(_ file: String) throws -> [String: Any] {
            let data = try Data(contentsOf: root.appendingPathComponent(file))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], file)
        }
        for file in ["App/CatchMyTrain.entitlements", "Widget/CatchMyTrainWidget.entitlements"] {
            let list = try entitlements(file)
            XCTAssertEqual(list["com.apple.security.app-sandbox"] as? Bool, true, file)
            XCTAssertEqual(list[SharedFolder.entitlement] as? [String], [SharedFolder.homeRelativePath], "\(file) names the shared folder, and only it")
            XCTAssertNil(list[groups], "\(file) holds an App Group")
            XCTAssertTrue(list.keys.allSatisfy { $0 == SharedFolder.entitlement || !$0.contains("temporary-exception") }, "\(file) has another sandbox exception")
        }
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("          - " + SharedFolder.homeRelativePath + "\n"), "project.yml names the widget's shared folder")
        XCTAssertFalse(project.contains(groups), "project.yml gives the widget no App Group")
    }

    /// Images and icon sources carry no embedded provenance metadata (C2PA manifests name the tools that made them).
    func testNoEmbeddedMetadataInImages() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let skippedFolders: Set<String> = [".build", "build", ".git", ".swiftpm", "xcuserdata"]
        let imageExtensions: Set<String> = ["png", "svg", "pdf", "jpg", "jpeg", "mjs"]
        let marker = Data("c2pa".utf8)
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in files {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skippedFolders.contains(url.lastPathComponent) { files.skipDescendants() }
                continue
            }
            guard imageExtensions.contains(url.pathExtension.lowercased()), let data = try? Data(contentsOf: url) else { continue }
            XCTAssertNil(data.range(of: marker), "\(url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.path + "/", with: "")) has embedded metadata; run tools/icon/strip-png-metadata.py")
        }
    }

    /// The version and build number are written by hand in 8 places: twice each in project.yml (app and widget) and in both
    /// Info.plist files. They must all agree, or the widget reports a different version than the app.
    func testVersionNumbersMatch() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        func values(_ key: String) throws -> [String] {
            let regex = try NSRegularExpression(pattern: "^\\s*\(key): \"([^\"]*)\"\\s*$", options: .anchorsMatchLines)
            let ns = project as NSString
            return regex.matches(in: project, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
        var versions = try values("CFBundleShortVersionString")
        var builds = try values("CFBundleVersion")
        XCTAssertEqual(versions.count, 2, "project.yml should set the version for the app and the widget")
        XCTAssertEqual(builds.count, 2, "project.yml should set the build number for the app and the widget")
        for plist in ["App/Info.plist", "Widget/Info.plist"] {
            let data = try Data(contentsOf: root.appendingPathComponent(plist))
            let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], plist)
            versions.append(try XCTUnwrap(info["CFBundleShortVersionString"] as? String, plist))
            builds.append(try XCTUnwrap(info["CFBundleVersion"] as? String, plist))
        }
        XCTAssertEqual(Set(versions).count, 1, "versions differ: \(versions)")
        XCTAssertEqual(Set(builds).count, 1, "build numbers differ: \(builds)")
        XCTAssertNotNil(Int(builds[0]), "the build number is a whole number")
    }

    /// Xcode builds only the Swift files its project lists one by one: CatchCore's sources come with the package, but the app's, the
    /// widget's, the shared ones and every test file are listed in project.pbxproj. A file left out there is never built on the Mac, so
    /// its tests never run there, and nothing else notices: the package's own build finds every file in its folders by itself.
    func testEverySwiftFileIsInTheXcodeProject() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let project = try String(contentsOf: root.appendingPathComponent("CatchMyTrain.xcodeproj/project.pbxproj"), encoding: .utf8)
        var checked = 0
        for folder in ["App", "Shared", "Widget", "AppTests", "Packages/CatchCore/Tests"] {
            guard let files = fm.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let name = url.lastPathComponent
                let path = url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.path + "/", with: "")
                checked += 1
                XCTAssertTrue(project.contains("path = \(name);") || project.contains("path = \"\(name)\";"),
                              "project.pbxproj has no file reference for \(path)")
                XCTAssertTrue(project.contains("/* \(name) in Sources */"),
                              "\(path) isn't in any target's Sources in project.pbxproj, so Xcode never builds it")
            }
        }
        XCTAssertGreaterThan(checked, 50, "found too few Swift files; is the project root right?")
    }

    /// Xcode reads project.pbxproj as an old-style property list before it builds anything. One value written without quotes where it
    /// needs them (a file name with "+" in it, for example) makes the whole project unreadable, and then nothing is compiled at all.
    /// New files are added to the project file by hand, so this reads it the way Xcode does, and checks that every object another
    /// one points to is there. It can go once the project file is no longer edited by hand.
    func testXcodeProjectFileIsReadable() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let data = try Data(contentsOf: root.appendingPathComponent("CatchMyTrain.xcodeproj/project.pbxproj"))
        guard let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return XCTFail("project.pbxproj isn't a readable property list, so Xcode can't open the project. Look for a value that "
                           + "needs quotes: one with anything but letters, digits, \".\", \"_\", \"/\" and \"$\" in it")
        }
        let project = try XCTUnwrap(list as? [String: Any], "project.pbxproj should be a dictionary")
        let objects = try XCTUnwrap(project["objects"] as? [String: Any], "project.pbxproj has no objects")
        // An object's ID: 24 characters, each a digit or a letter from A to F
        func isID(_ text: String) -> Bool {
            text.utf8.count == 24 && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
        }
        var pointers = 0
        func check(_ value: Any, from id: String, key: String) {
            if let text = value as? String {
                guard isID(text) else { return }
                pointers += 1
                XCTAssertNotNil(objects[text], "\(id) points to \(text) in \(key), which project.pbxproj doesn't have")
            } else if let items = value as? [Any] {
                for item in items { check(item, from: id, key: key) }
            }
        }
        XCTAssertNotNil(objects[project["rootObject"] as? String ?? ""], "project.pbxproj's rootObject isn't among its objects")
        for (id, object) in objects {
            for (key, value) in try XCTUnwrap(object as? [String: Any], id) { check(value, from: id, key: key) }
        }
        XCTAssertGreaterThan(pointers, 200, "found too few references between objects; has the project file's shape changed?")
    }

    /// The Developer Team is personal, so it stays out of the repository: Signing.xcconfig includes Local.xcconfig, which git ignores.
    /// Choosing a Team in Xcode's Signing settings writes it back into the project file; this catches that.
    func testProjectFilesNameNoDeveloperTeam() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let team = try NSRegularExpression(pattern: #"(?:DEVELOPMENT_TEAM|DevelopmentTeam)\s*[:=]\s*"?[A-Z0-9]{10}\b"#)
        for file in ["project.yml", "CatchMyTrain.xcodeproj/project.pbxproj", "Signing.xcconfig", "Local.xcconfig.example"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertNil(team.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                         "\(file) names a Developer Team; it belongs in Local.xcconfig")
        }
        let signing = try String(contentsOf: root.appendingPathComponent("Signing.xcconfig"), encoding: .utf8)
        XCTAssertTrue(signing.contains(#"#include? "Local.xcconfig""#), "Signing.xcconfig should include Local.xcconfig, and only if it exists")
        let ignored = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(ignored.split(separator: "\n").contains("Local.xcconfig"), ".gitignore should keep Local.xcconfig out of git")
    }

    /// The system colors still written directly in the app, the widget and Shared, outside the palette (Shared/UIText.swift), by file.
    /// White and black aren't counted (white on solid colors and the line badges' black and white are allowed)
    static let registeredColors: [String: [String: Int]] = [:]

    /// Colors are named in the palette and used by name: a system color written directly anywhere else must be in the list above,
    /// as many times as it is there. Animations go through Motion, which follows "Reduce motion"
    func testColorsAndAnimationsFollowTheRules() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let hues = "red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|grey"
        // Color.red, NSColor.red, NSColor.systemRed, .systemRed, and .red where a color is expected (.foregroundStyle(.red))
        let color = try NSRegularExpression(pattern: #"\b(?:Color|NSColor)\.(?:system)?("# + hues + #")\b|(?<![\w)\]"])\.system("#
            + hues + #")\b|(?<![\w)\]"])\.("# + hues + #")\b"#, options: .caseInsensitive)
        // An animation that isn't Motion's, or none
        let animation = try NSRegularExpression(pattern: #"withAnimation\s*(?:\{|\((?!\s*Motion\.))|\.animation\((?!\s*(?:Motion\.|nil\b))|\.animation\s*=(?!\s*(?:nil\b|Motion\.))"#)
        var found: [String: [String: Int]] = [:]
        var checked = 0
        for folder in ["App", "Widget", "Shared"] {
            guard let files = fm.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let path = folder + "/" + url.path.components(separatedBy: "/" + folder + "/").last!
                let text = try String(contentsOf: url, encoding: .utf8)
                checked += 1
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    // Code only: comments say what was done, and may name a color or an animation
                    let code = String(line.components(separatedBy: "//").first ?? "")
                    let range = NSRange(code.startIndex..., in: code)
                    XCTAssertNil(animation.firstMatch(in: code, range: range),
                                 "\(path):\(number + 1) animates without Motion, so it ignores \"Reduce motion\": use Motion (App/CatchMyTrainApp.swift)")
                    guard path != "Shared/UIText.swift" else { continue }
                    for match in color.matches(in: code, range: range) {
                        guard let name = (1...3).lazy.compactMap({ Range(match.range(at: $0), in: code) }).first.map({ code[$0].lowercased() })
                        else { continue }
                        found[path, default: [:]][name == "grey" ? "gray" : name, default: 0] += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 30, "found too few files; is the project root right?")
        for (path, colors) in found {
            for (name, count) in colors where count > Self.registeredColors[path]?[name] ?? 0 {
                XCTFail("\(path) uses Color.\(name) \(count) times, \(Self.registeredColors[path]?[name] ?? 0) registered: add the color to the "
                    + "palette (Shared/UIText.swift), or register it in the list here")
            }
        }
        for (path, colors) in Self.registeredColors {
            for (name, count) in colors where count > found[path]?[name] ?? 0 {
                XCTFail("\(path) uses Color.\(name) \(found[path]?[name] ?? 0) times, \(count) registered: take it out of the list here")
            }
        }
    }

    /// The color and animation patterns above catch what they should
    func testColorAndAnimationPatterns() throws {
        // Kept in step with testColorsAndAnimationsFollowTheRules
        let hues = "red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|grey"
        let color = try NSRegularExpression(pattern: #"\b(?:Color|NSColor)\.(?:system)?("# + hues + #")\b|(?<![\w)\]"])\.system("#
            + hues + #")\b|(?<![\w)\]"])\.("# + hues + #")\b"#, options: .caseInsensitive)
        let animation = try NSRegularExpression(pattern: #"withAnimation\s*(?:\{|\((?!\s*Motion\.))|\.animation\((?!\s*(?:Motion\.|nil\b))|\.animation\s*=(?!\s*(?:nil\b|Motion\.))"#)
        func matches(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        for line in [".fill(Color.red)", ".foregroundStyle(.orange)", "NSColor.systemBlue", "Color(nsColor: .systemGreen)", ".tint(Color.purple.opacity(0.4))"] {
            XCTAssertTrue(matches(color, line), line)
        }
        for line in [".foregroundStyle(.secondary)", "Color.noticeOrange", "Color.accentColor", "Color.walkRange", "route.blue"] {
            XCTAssertFalse(matches(color, line), line)
        }
        for line in ["withAnimation(.easeIn) {", "withAnimation {", ".animation(.easeOut(duration: 0.15), value: x)", "$0.animation = .default"] {
            XCTAssertTrue(matches(animation, line), line)
        }
        for line in ["withAnimation(Motion.ease(0.2)) {", ".animation(Motion.segments, value: x)", ".animation(nil, value: x)", "$0.animation = nil"] {
            XCTAssertFalse(matches(animation, line), line)
        }
    }

    /// The transit map's window never asks MapKit where a place is on its view: asking (MapProxy.convert) makes SwiftUI bring the
    /// whole window up to date first, and that never finished more than once, with the map window open (see MapScreen). So the
    /// transit map's files have no MapReader, and so no MapProxy to ask; where places are comes from the area the map reports
    /// (MapProjection). Comments may name them. Plan a Trip's map (PlannerMap) still asks, and isn't checked here
    func testTransitMapNeverAsksMapKit() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fm = FileManager.default
        let views = root.appendingPathComponent("App/Views")
        guard fm.fileExists(atPath: views.path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let asking = try NSRegularExpression(pattern: #"\bMapReader\b|\bMapProxy\b|\.convert\(|\bMapScreen\(asking"#)
        func asks(_ line: String) -> Bool {
            !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && asking.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        XCTAssertTrue(asks("            MapReader { proxy in"))
        XCTAssertTrue(asks("    func originFrame(_ proxy: MapProxy) -> CGRect? {"))
        XCTAssertTrue(asks("                        guard let c = proxy.convert(point, from: .local) else { return }"))
        XCTAssertTrue(asks("        return mayAsk ? MapScreen(asking: proxy, size: size) : nil"))
        XCTAssertFalse(asks("    /// Never asks MapKit: no MapReader, so no MapProxy.convert (see MapScreen)"))
        XCTAssertFalse(asks("                        guard let tapped = screen.coordinate(at: point) else { return }"))
        XCTAssertFalse(asks("                                   proxy: nil, inSight: mapInSight,"))
        let files = try fm.contentsOfDirectory(atPath: views.path)
            .filter { $0.hasPrefix("SubwayMapView") && $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertGreaterThanOrEqual(files.count, 5, "found too few of the transit map's files: \(files)")
        for name in files {
            let lines = try String(contentsOf: views.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() where asks(String(line)) {
                XCTFail("App/Views/\(name):\(number + 1) asks MapKit where a place is (MapReader, MapProxy, convert); use MapScreen")
            }
        }
    }

    /// Each map is made in one place only (Plan a Trip's in two: the column's and the large one), and what stopped maps from being
    /// taken away and made anew stays out: a map view taken away isn't always let go of, and each one stayed in memory. Unit tests
    /// can't see this, so a change back fails here
    func testEachMapIsMadeInOnePlace() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fm = FileManager.default
        let app = root.appendingPathComponent("App")
        guard fm.fileExists(atPath: app.appendingPathComponent("Views").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let making = try NSRegularExpression(pattern: #"\b(SubwayMapView|PickerMap|PlannerMapView)\("#)
        func code(_ line: Substring) -> Bool { !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        func made(_ line: String) -> [String] {
            making.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { m in
                Range(m.range(at: 1), in: line).map { String(line[$0]) }
            }
        }
        XCTAssertEqual(made("        PickerMap(l: l, large: large, system: transit.system, start: mapStart, focus: focus,"), ["PickerMap"])
        XCTAssertEqual(made("            PlannerMapView(l: l, large: true, place: place, start: walkingFrom,"), ["PlannerMapView"])
        XCTAssertEqual(made("        SubwayMapView(board: transit.board(at: BoardClock.now()), system: transit.system) { id in"),
                       ["SubwayMapView"])
        XCTAssertEqual(made("struct PickerMap: View {"), [])
        XCTAssertEqual(made("                        PlannerMapView.circles(around: center, settings: settings)"), [])
        var places: [String: [String]] = [:]
        var texts: [String: String] = [:]
        let walker = fm.enumerator(atPath: app.path)
        while let path = walker?.nextObject() as? String {
            guard path.hasSuffix(".swift") else { continue }
            let text = try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
            texts[path] = text
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where code(line) {
                for name in made(String(line)) { places[name, default: []].append("App/\(path):\(number + 1)") }
            }
        }
        XCTAssertEqual(places["SubwayMapView"]?.count, 1, "the transit map is made in one place only: \(places["SubwayMapView"] ?? [])")
        XCTAssertEqual(places["PickerMap"]?.count, 1,
                       "the place picker's map is made in one place only (it grows into the large one): \(places["PickerMap"] ?? [])")
        XCTAssertEqual(places["PlannerMapView"]?.count, 2,
                       "Plan a Trip's maps are made in two places only (column, large map): \(places["PlannerMapView"] ?? [])")
        let picker = try XCTUnwrap(texts["Views/PlacePickerSheet+Map.swift"], "the place picker's map file wasn't found")
        XCTAssertFalse(picker.contains(".id(transit.pickerOpenCount)"), "the place picker's map is not made anew on each open")
        // Where the views holding a map are called: one place each, so the two columns' map and the large one are the same map
        // (a second call of pickerMap or a page of its own for the large map would make a second one)
        let calling = { (name: String) throws -> NSRegularExpression in
            try NSRegularExpression(pattern: #"(?<!func )\b"# + name + #"\("#)
        }
        func calls(_ name: String) throws -> [String] {
            let pattern = try calling(name)
            var found: [String] = []
            for (path, text) in texts {
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where code(line) {
                    let s = String(line)
                    if pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { found.append("App/\(path):\(number + 1)") }
                }
            }
            return found
        }
        XCTAssertEqual(try calling("pickerMap").firstMatch(in: "    func pickerMap(_ l: UIText, large: Bool) -> some View {",
                                                          range: NSRange(location: 0, length: 52)) == nil, true)
        for name in ["pickerMap", "rightColumn", "mapColumn", "largeMapArea"] {
            let found = try calls(name)
            XCTAssertEqual(found.count, 1, "\(name) is called in one place only, so its map is made once: \(found)")
        }
        XCTAssertFalse(texts.values.contains { $0.contains("largeMapPage") }, "the place picker has no page of its own for the large map")
        // Plan a Trip: each map is kept once made (hidden, not taken away), and the large map isn't a branch in place of the list
        let planner = try XCTUnwrap(texts["Views/PlannerView+Map.swift"], "Plan a Trip's map file wasn't found")
        XCTAssertTrue(planner.contains("large || largeMapMade"), "Plan a Trip's large map is kept once made")
        XCTAssertTrue(planner.contains("place != nil || smallMapMade"), "Plan a Trip's small map is kept once made")
        let areaStart = try XCTUnwrap(planner.range(of: "func mainArea("), "Plan a Trip's mainArea wasn't found")
        let areaRest = planner[areaStart.lowerBound...]
        let mainArea = areaRest[..<(areaRest.range(of: "\n    }\n")?.upperBound ?? areaRest.endIndex)]
        XCTAssertTrue(mainArea.contains("keptHidden"), "Plan a Trip's mainArea wasn't read whole")
        XCTAssertFalse(mainArea.contains("else if showsMapColumn"), "Plan a Trip's large map is not shown in place of the list")
        let appFile = try XCTUnwrap(texts["CatchMyTrainApp.swift"], "the app file wasn't found")
        let start = try XCTUnwrap(appFile.range(of: "struct MapWindowView"), "the map window's view wasn't found")
        let rest = appFile[start.lowerBound...]
        let mapWindow = rest[..<(rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex)]
        XCTAssertTrue(mapWindow.contains("SubwayMapView("), "the map window's view wasn't read whole")
        for line in mapWindow.split(separator: "\n") where code(line) {
            XCTAssertFalse(line.contains(".pushIn("), "the map window draws another mode on the same map, not a new one: \(line)")
        }
    }
}

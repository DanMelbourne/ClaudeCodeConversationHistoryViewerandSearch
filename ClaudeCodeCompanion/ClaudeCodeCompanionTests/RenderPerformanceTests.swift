import XCTest
@testable import Claude_Code_Companion

/// Regression cover for the main-thread stalls Sentry reported as app hangs.
///
/// These are invariant tests, not micro-benchmarks: each asserts that a render
/// path stays well inside the 2 s app-hang threshold on input the app really
/// sees, and that the fast path still produces the same output as the slow one.
@MainActor
final class RenderPerformanceTests: XCTestCase {

    // MARK: - Inline markdown parsing

    /// The original parser retried five unbounded regexes against the whole
    /// remaining string once per unmatched trigger character. A 16 KB line of
    /// ordinary prose containing snake_case identifiers took ~7.9 s.
    func testInlineParsingOfLongTriggerHeavyLineStaysFast() {
        let unit = "the value of some_snake_case_name in module_two was checked against other_value and logged. "
        var line = ""
        while line.count < 16_000 { line += unit }
        line = String(line.prefix(16_000))
        XCTAssertGreaterThan(line.filter { $0 == "_" }.count, 500, "input must exercise the trigger path")

        let start = Date()
        _ = MarkdownParser.inlineText(line)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 0.5,
            "16 KB line took \(elapsed)s — inline parsing has regressed to superlinear"
        )
    }

    /// A lone unmatched delimiter must not send the parser scanning to the end
    /// of the line. This is the exact shape that produced the hang.
    func testUnmatchedDelimitersDoNotBacktrack() {
        let line = String(repeating: "a * b _ c [ d ` e ", count: 1_000)

        let start = Date()
        _ = MarkdownParser.inlineText(line)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.5, "unmatched delimiters took \(elapsed)s")
    }

    func testInlineParsingScalesLinearly() {
        func cost(_ length: Int) -> TimeInterval {
            var line = ""
            while line.count < length { line += "some_identifier and more_text here " }
            line = String(line.prefix(length))
            let start = Date()
            _ = MarkdownParser.inlineText(line)
            return Date().timeIntervalSince(start)
        }

        _ = cost(2_000) // warm up the regex engine
        let small = cost(2_000)
        let large = cost(16_000)

        // 8x the input must not cost more than 24x the time. The old parser was
        // ~40x here; a true quadratic blowup is far worse than that.
        XCTAssertLessThan(large, max(small * 24, 0.2), "growth from 2 KB (\(small)s) to 16 KB (\(large)s) is superlinear")
    }

    // MARK: - Markdown structure still parses correctly

    func testMarkdownBlocksAreStillRecognised() {
        let source = """
        # Heading
        Some paragraph with **bold** and `code`.
        - a bullet
        1. a numbered item

        ```swift
        let x = 1
        ```
        """

        let elements = MarkdownParser.parse(source)

        func has(_ predicate: (MarkdownElement) -> Bool) -> Bool { elements.contains(where: predicate) }

        XCTAssertTrue(has { if case .header(let level, _) = $0 { return level == 1 }; return false })
        XCTAssertTrue(has { if case .paragraph = $0 { return true }; return false })
        XCTAssertTrue(has { if case .bulletItem = $0 { return true }; return false })
        XCTAssertTrue(has { if case .numberedItem(let n, _) = $0 { return n == "1" }; return false })
        XCTAssertTrue(has {
            if case .codeBlock(let lang, let code) = $0 { return lang == "swift" && code == "let x = 1" }
            return false
        })
    }

    /// A pasted image arrives base64-encoded on one line. Laying the whole
    /// thing out as a single `Text` is what blocks the main thread.
    func testOversizedMessageIsTruncatedForDisplay() {
        let huge = String(repeating: "A", count: MarkdownParser.displayLimit + 50_000)
        let elements = MarkdownParser.parse(huge)
        XCTAssertFalse(elements.isEmpty)
        XCTAssertTrue(
            elements.contains { if case .paragraph = $0 { return true }; return false },
            "truncated content should still render"
        )
    }

    func testParseCacheReturnsEqualElementCountOnRepeatLookup() {
        let source = "# Title\nbody with `code`\n- item"
        let first = MarkdownCache.shared.elements(for: source)
        let second = MarkdownCache.shared.elements(for: source)
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(first.count, MarkdownParser.parse(source).count)
    }

    // MARK: - Row building

    private func message(id: String, offsetMinutes: Double, type: ConversationMessage.MessageType = .user) -> ParsedMessage {
        ParsedMessage(
            id: id,
            type: type,
            timestamp: Date(timeIntervalSince1970: offsetMinutes * 60),
            blocks: [.text("body \(id)")],
            rawJSON: "{}"
        )
    }

    func testDateDividerAppearsOnlyAfterALongGap() {
        let rows = ConversationDisplayRowBuilder.makeRows(from: [
            message(id: "a", offsetMinutes: 0),
            message(id: "b", offsetMinutes: 5),    // 5 min later — no divider
            message(id: "c", offsetMinutes: 60),   // 55 min later — divider
        ])

        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(rows[0].showsDateDivider, "the first row never gets a divider")
        XCTAssertFalse(rows[1].showsDateDivider)
        XCTAssertTrue(rows[2].showsDateDivider)
    }

    /// Row building must stay linear. The previous code re-filtered the whole
    /// message array inside the ForEach body, once per visible row.
    func testRowBuildingIsLinearInMessageCount() {
        let messages = (0..<20_000).map { message(id: "\($0)", offsetMinutes: Double($0)) }

        let start = Date()
        let rows = ConversationDisplayRowBuilder.makeRows(from: messages)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(rows.count, messages.count)
        XCTAssertLessThan(elapsed, 0.5, "building 20k rows took \(elapsed)s")
    }

    // MARK: - In-conversation search

    func testLocalSearchMatchesAcrossBlockKinds() {
        let messages = [
            ParsedMessage(id: "text", type: .assistant, timestamp: Date(), blocks: [.text("hello NEEDLE there")], rawJSON: "{}"),
            ParsedMessage(id: "thinking", type: .assistant, timestamp: Date(), blocks: [.thinking("a needle inside")], rawJSON: "{}"),
            ParsedMessage(id: "tool", type: .assistant, timestamp: Date(), blocks: [.toolUse(name: "Grep", inputJSON: "{\"q\":\"needle\"}")], rawJSON: "{}"),
            ParsedMessage(id: "result", type: .user, timestamp: Date(), blocks: [.toolResult(content: "no match here")], rawJSON: "{}"),
        ]

        let rows = ConversationDisplayRowBuilder.makeRows(from: messages, showSystemMessages: true)
        let matches = ConversationView.matchingMessageIDs(in: rows, query: "needle")

        XCTAssertEqual(matches, ["text", "thinking", "tool"], "search is case-insensitive across every block kind")
    }

    func testLocalSearchWithNoMatchesReturnsEmpty() {
        let messages = [message(id: "a", offsetMinutes: 0)]
        let rows = ConversationDisplayRowBuilder.makeRows(from: messages, showSystemMessages: true)
        XCTAssertTrue(ConversationView.matchingMessageIDs(in: rows, query: "zzz-not-present").isEmpty)
    }

    // MARK: - Line counting

    func testLineCountingMatchesActualNewlineCount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Deliberately larger than one read buffer so the chunk boundary is covered.
        let line = String(repeating: "x", count: 997) + "\n"
        let expected = 3_000
        let file = directory.appendingPathComponent("session.jsonl")
        try String(repeating: line, count: expected).write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(AppViewModel.countLinesEfficient(in: file), expected)
    }

    func testLineCountingHandlesEmptyAndMissingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let empty = directory.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)
        XCTAssertEqual(AppViewModel.countLinesEfficient(in: empty), 0)

        let missing = directory.appendingPathComponent("nope.jsonl")
        XCTAssertEqual(AppViewModel.countLinesEfficient(in: missing), 0)
    }

    func testLineCountingHandlesFileWithoutTrailingNewline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("partial.jsonl")
        try "a\nb\nc".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(AppViewModel.countLinesEfficient(in: file), 2, "counts newlines, matching the previous implementation")
    }
}

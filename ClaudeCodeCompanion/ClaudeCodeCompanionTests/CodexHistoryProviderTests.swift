import XCTest
@testable import Claude_Code_Companion

final class CodexHistoryProviderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// Codex terminates every record with a newline, so fixtures do too — the
    /// resume point is only allowed to advance past complete lines.
    private func writeRollout(_ lines: [String], name: String = "rollout-2026-01-01T00-00-00-abc.jsonl") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var sessionMeta: String {
        """
        {"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{"session_id":"sess-1","cwd":"/Users/dan/Code/My App","git":{"branch":"main"}}}
        """
    }

    // MARK: - Tests

    func testParsesUserAndAssistantMessages() throws {
        let url = try writeRollout([
            sessionMeta,
            #"{"timestamp":"2026-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the build"}]}}"#,
            #"{"timestamp":"2026-01-01T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#
        ])

        let session = try XCTUnwrap(CodexHistoryProvider.parseSession(at: url))

        XCTAssertEqual(session.id, "sess-1")
        XCTAssertEqual(session.workingDirectory, "/Users/dan/Code/My App")
        XCTAssertEqual(session.gitBranch, "main")
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.messages[0].type, .user)
        XCTAssertEqual(session.messages[0].contentText, "fix the build")
        XCTAssertEqual(session.messages[1].type, .assistant)
        XCTAssertTrue(session.messages.allSatisfy { $0.agent == .codex })
        XCTAssertTrue(session.messages.allSatisfy { $0.sessionId == "sess-1" })
    }

    /// The transcoded records must render through the existing Claude parser —
    /// that is the whole point of the Claude-shaped adapter.
    func testTranscodedRecordsRenderAsBlocks() throws {
        let url = try writeRollout([
            sessionMeta,
            #"{"timestamp":"2026-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"weighing options"}]}}"#,
            #"{"timestamp":"2026-01-01T00:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"cmd\":\"ls\"}","call_id":"c1"}}"#,
            #"{"timestamp":"2026-01-01T00:00:03.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":[{"type":"input_text","text":"README.md"}]}}"#
        ])

        let session = try XCTUnwrap(CodexHistoryProvider.parseSession(at: url))
        let blocks = session.messages.flatMap { JSONLParser.parseContentBlocks(from: $0.contentRaw) }

        XCTAssertEqual(blocks.count, 3)
        guard case .thinking(let thought) = blocks[0] else { return XCTFail("expected thinking block") }
        XCTAssertEqual(thought, "weighing options")

        guard case .toolUse(let name, let inputJSON) = blocks[1] else { return XCTFail("expected tool_use block") }
        XCTAssertEqual(name, "shell")
        XCTAssertTrue(inputJSON.contains("\"cmd\""), "arguments should decode to JSON, got \(inputJSON)")

        guard case .toolResult(let output) = blocks[2] else { return XCTFail("expected tool_result block") }
        XCTAssertEqual(output, "README.md")
    }

    /// Thinking must stay out of the searchable text, matching Claude sessions.
    func testThinkingIsExcludedFromIndexedText() throws {
        let url = try writeRollout([
            sessionMeta,
            #"{"timestamp":"2026-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"secret plan"}]}}"#
        ])

        let session = try XCTUnwrap(CodexHistoryProvider.parseSession(at: url))
        XCTAssertEqual(session.messages.first?.contentText, "")
    }

    func testEventMessagesAreNotDuplicated() throws {
        let url = try writeRollout([
            sessionMeta,
            #"{"timestamp":"2026-01-01T00:00:01.000Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}"#,
            #"{"timestamp":"2026-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#
        ])

        let session = try XCTUnwrap(CodexHistoryProvider.parseSession(at: url))
        XCTAssertEqual(session.messages.count, 1)
    }

    func testHeaderReadsWorkingDirectoryWithoutParsingBody() throws {
        let url = try writeRollout([
            sessionMeta,
            #"{"timestamp":"2026-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#
        ])

        let header = try XCTUnwrap(CodexHistoryProvider.readHeader(at: url))
        XCTAssertEqual(header.id, "sess-1")
        XCTAssertEqual(header.workingDirectory, "/Users/dan/Code/My App")
    }

    func testMalformedLinesAreSkipped() throws {
        let url = try writeRollout([
            sessionMeta,
            "{not json at all",
            "",
            #"{"timestamp":"2026-01-01T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"still here"}]}}"#
        ])

        let session = try XCTUnwrap(CodexHistoryProvider.parseSession(at: url))
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].contentText, "still here")
    }

    private func writeLargeRollout(messageCount: Int) throws -> URL {
        var lines = [sessionMeta]
        for index in 0..<messageCount {
            lines.append(
                #"{"timestamp":"2026-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"msg \#(index)"}]}}"#
            )
        }
        return try writeRollout(lines)
    }

    /// Appending must cost only the appended bytes: resuming from the recorded
    /// offset returns the new messages and nothing else.
    func testResumeFromOffsetReadsOnlyNewMessages() throws {
        let url = try writeLargeRollout(messageCount: 20)

        var firstPass: [ConversationMessage] = []
        var offset = 0
        _ = CodexHistoryProvider.stream(at: url, batchSize: 1_000) { batch, _, consumed in
            firstPass.append(contentsOf: batch)
            offset = consumed
        }
        XCTAssertEqual(firstPass.count, 20)
        XCTAssertGreaterThan(offset, 0)

        let appended = #"{"timestamp":"2026-01-01T00:00:09.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"after the resume"}]}}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appended + "\n").utf8))
        try handle.close()

        var secondPass: [ConversationMessage] = []
        let info = CodexHistoryProvider.stream(at: url, batchSize: 1_000, fromByteOffset: offset) { batch, _, _ in
            secondPass.append(contentsOf: batch)
        }

        XCTAssertEqual(secondPass.map(\.contentText), ["after the resume"])
        XCTAssertEqual(info?.id, "sess-1", "the header must still be read when resuming")
        XCTAssertEqual(info?.workingDirectory, "/Users/dan/Code/My App")
    }

    /// Ids must not collide between a first pass and a resumed pass, or the
    /// index would hold two different messages under one uuid.
    func testMessageIdsAreStableAcrossPasses() throws {
        let url = try writeLargeRollout(messageCount: 6)

        var full: [String] = []
        _ = CodexHistoryProvider.stream(at: url, batchSize: 2) { batch, _, _ in
            full.append(contentsOf: batch.map(\.id))
        }
        var again: [String] = []
        _ = CodexHistoryProvider.stream(at: url, batchSize: 3) { batch, _, _ in
            again.append(contentsOf: batch.map(\.id))
        }

        XCTAssertEqual(full, again, "ids must not depend on batching")
        XCTAssertEqual(Set(full).count, full.count, "ids must be unique")
    }

    /// Indexing must see every message of an oversized rollout — that is what
    /// makes the whole session searchable.
    func testStreamingCoversEveryMessage() throws {
        let url = try writeLargeRollout(messageCount: 5_000)

        var streamed = 0
        var batchSizes: [Int] = []
        let info = CodexHistoryProvider.stream(at: url, batchSize: 500) { batch, _, _ in
            streamed += batch.count
            batchSizes.append(batch.count)
        }

        XCTAssertEqual(streamed, 5_000)
        XCTAssertEqual(info?.id, "sess-1")
        XCTAssertTrue(batchSizes.allSatisfy { $0 <= 500 }, "batches must stay bounded: \(batchSizes.max() ?? 0)")
    }

    /// Display keeps the opening and closing stretches and states what it left
    /// out, rather than silently dropping the end of the conversation.
    func testDisplayWindowKeepsHeadAndTailWithNotice() throws {
        let url = try writeLargeRollout(messageCount: 900)

        let session = try XCTUnwrap(CodexHistoryProvider.parseSession(at: url, headLimit: 100, tailLimit: 100))

        XCTAssertEqual(session.messages.count, 201, "100 head + notice + 100 tail")
        XCTAssertEqual(session.messages.first?.contentText, "msg 0")
        XCTAssertEqual(session.messages.last?.contentText, "msg 899")
        let notice = session.messages[100]
        XCTAssertEqual(notice.type, .system)
        XCTAssertTrue(notice.contentText.contains("700 messages"), "got: \(notice.contentText)")
    }

    func testDisplayWindowAddsNoNoticeForSmallSessions() throws {
        let url = try writeLargeRollout(messageCount: 10)
        let session = try XCTUnwrap(CodexHistoryProvider.parseSession(at: url, headLimit: 100, tailLimit: 100))

        XCTAssertEqual(session.messages.count, 10)
        XCTAssertFalse(session.messages.contains { $0.type == .system })
    }

    func testRolloutWithoutMessagesIsIgnored() throws {
        let url = try writeRollout([sessionMeta])
        XCTAssertNil(CodexHistoryProvider.parseSession(at: url))
    }

    func testRolloutDiscoveryFindsNestedFiles() throws {
        let nested = directory.appendingPathComponent("2026/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let url = nested.appendingPathComponent("rollout-a.jsonl")
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        try "ignore me".write(to: nested.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let files = CodexHistoryProvider.rolloutFiles(under: directory)
        XCTAssertEqual(files.map(\.lastPathComponent), ["rollout-a.jsonl"])
    }

    func testMissingDirectoryYieldsNoFiles() {
        let missing = directory.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertTrue(CodexHistoryProvider.rolloutFiles(under: missing).isEmpty)
    }

    // MARK: - Project path encoding

    func testWorkingDirectoryEncodesToClaudeFolderName() {
        XCTAssertEqual(
            ProjectPathEncoder.encodedFolderName(for: "/Users/dan/Code/Kids Expenses"),
            "-Users-dan-Code-Kids-Expenses"
        )
        XCTAssertEqual(
            ProjectPathEncoder.encodedFolderName(for: "/Users/dan/Code/Backup-system"),
            "-Users-dan-Code-Backup-system"
        )
    }

    /// Round trip: a Codex session in a folder Claude Code also worked in must
    /// land on the same project row.
    func testCodexProjectPathMatchesClaudeFolder() throws {
        let url = try writeRollout([
            sessionMeta,
            #"{"timestamp":"2026-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#
        ])
        let session = try XCTUnwrap(CodexHistoryProvider.parseSession(at: url))
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/-Users-dan-Code-My-App").path
        XCTAssertEqual(session.projectPath, expected)
    }
}

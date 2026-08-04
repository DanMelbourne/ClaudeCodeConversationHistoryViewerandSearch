import SQLite3
import XCTest
@testable import Claude_Code_Companion

final class CursorHistoryProviderTests: XCTestCase {

    private var directory: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("state.vscdb")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixture builder

    /// Build a miniature copy of Cursor's key/value store.
    private func makeDatabase(rows: [(String, String)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value BLOB)", nil, nil, nil),
            SQLITE_OK
        )
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (key, value) in rows {
            var stmt: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(db, "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)", -1, &stmt, nil),
                SQLITE_OK
            )
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, transient)
            sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, transient)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    private func standardFixture() throws {
        let composer = """
        {"composerId":"c1","name":"Fix the logo bug","createdAt":1780000000000,"lastUpdatedAt":1780000600000,
         "trackedGitRepos":[{"repoPath":"/Users/dan/Code/ScreenshotTray"}],
         "fullConversationHeadersOnly":[{"bubbleId":"b1","type":1},{"bubbleId":"b2","type":2},{"bubbleId":"b3","type":2}]}
        """
        let userBubble = #"{"bubbleId":"b1","type":1,"text":"the delete key does nothing","createdAt":"2026-06-04T07:04:40.036Z"}"#
        let assistantBubble = #"{"bubbleId":"b2","type":2,"text":"Tracing the handler.","thinking":{"text":"checking the key handler","signature":""},"createdAt":"2026-06-04T07:04:41.000Z"}"#
        let toolBubble = #"{"bubbleId":"b3","type":2,"toolFormerData":{"name":"read_file","params":"{\"path\":\"App.swift\"}","result":"line one"},"createdAt":"2026-06-04T07:04:42.000Z"}"#

        try makeDatabase(rows: [
            ("composerData:c1", composer),
            ("bubbleId:c1:b1", userBubble),
            ("bubbleId:c1:b2", assistantBubble),
            ("bubbleId:c1:b3", toolBubble)
        ])
    }

    // MARK: - Tests

    func testReadsConversationMetadata() throws {
        try standardFixture()

        let conversations = CursorHistoryProvider.conversations(databaseURL: dbURL)
        let conversation = try XCTUnwrap(conversations.first)

        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversation.id, "c1")
        XCTAssertEqual(conversation.title, "Fix the logo bug")
        XCTAssertEqual(conversation.workingDirectory, "/Users/dan/Code/ScreenshotTray")
        XCTAssertEqual(conversation.bubbleIds, ["b1", "b2", "b3"])
        XCTAssertEqual(conversation.indexKey, "cursor://composer/c1")
    }

    func testMessagesFollowHeaderOrderAndCarryAgent() throws {
        try standardFixture()

        let conversation = try XCTUnwrap(CursorHistoryProvider.conversations(databaseURL: dbURL).first)
        let messages = CursorHistoryProvider.messages(for: conversation, databaseURL: dbURL)

        XCTAssertEqual(messages.map(\.id), ["b1", "b2", "b3"])
        XCTAssertEqual(messages[0].type, .user)
        XCTAssertEqual(messages[1].type, .assistant)
        XCTAssertTrue(messages.allSatisfy { $0.agent == .cursor })
        XCTAssertTrue(messages.allSatisfy { $0.sessionId == "c1" })
        XCTAssertEqual(messages[0].cwd, "/Users/dan/Code/ScreenshotTray")
    }

    func testBubblesRenderAsBlocks() throws {
        try standardFixture()

        let conversation = try XCTUnwrap(CursorHistoryProvider.conversations(databaseURL: dbURL).first)
        let messages = CursorHistoryProvider.messages(for: conversation, databaseURL: dbURL)

        let assistantBlocks = JSONLParser.parseContentBlocks(from: messages[1].contentRaw)
        guard case .thinking(let thought) = assistantBlocks.first else {
            return XCTFail("expected leading thinking block")
        }
        XCTAssertEqual(thought, "checking the key handler")

        let toolBlocks = JSONLParser.parseContentBlocks(from: messages[2].contentRaw)
        guard case .toolUse(let name, let inputJSON) = toolBlocks.first else {
            return XCTFail("expected tool_use block")
        }
        XCTAssertEqual(name, "read_file")
        XCTAssertTrue(inputJSON.contains("App.swift"))
        guard case .toolResult(let output) = toolBlocks.last else {
            return XCTFail("expected tool_result block")
        }
        XCTAssertEqual(output, "line one")
    }

    func testConversationWithoutRepoUsesUnassignedProject() throws {
        let composer = """
        {"composerId":"c2","name":"Scratch","createdAt":1780000000000,
         "fullConversationHeadersOnly":[{"bubbleId":"b1","type":1}]}
        """
        try makeDatabase(rows: [
            ("composerData:c2", composer),
            ("bubbleId:c2:b1", #"{"bubbleId":"b1","type":1,"text":"hello"}"#)
        ])

        let conversation = try XCTUnwrap(CursorHistoryProvider.conversations(databaseURL: dbURL).first)
        XCTAssertNil(conversation.workingDirectory)
        XCTAssertEqual(
            conversation.projectPath,
            ProjectPathEncoder.projectPath(for: CursorHistoryProvider.Conversation.unassignedWorkingDirectory)
        )
    }

    func testEmptyConversationsAreSkipped() throws {
        try makeDatabase(rows: [
            ("composerData:c3", #"{"composerId":"c3","name":"Empty","fullConversationHeadersOnly":[]}"#)
        ])
        XCTAssertTrue(CursorHistoryProvider.conversations(databaseURL: dbURL).isEmpty)
    }

    func testMissingBubblesAreToleratedWithoutLosingOthers() throws {
        let composer = """
        {"composerId":"c4","name":"Partial","createdAt":1780000000000,
         "fullConversationHeadersOnly":[{"bubbleId":"gone","type":1},{"bubbleId":"here","type":2}]}
        """
        try makeDatabase(rows: [
            ("composerData:c4", composer),
            ("bubbleId:c4:here", #"{"bubbleId":"here","type":2,"text":"present"}"#)
        ])

        let conversation = try XCTUnwrap(CursorHistoryProvider.conversations(databaseURL: dbURL).first)
        let messages = CursorHistoryProvider.messages(for: conversation, databaseURL: dbURL)
        XCTAssertEqual(messages.map(\.id), ["here"])
    }

    /// A bubble carrying no renderable content must not create a blank row.
    func testEmptyBubbleProducesNoMessage() {
        let message = CursorHistoryProvider.message(
            fromBubble: ["type": 2],
            bubbleId: "b0",
            sessionId: "c0",
            timestamp: Date(),
            cwd: nil
        )
        XCTAssertNil(message)
    }

    func testMissingDatabaseIsHandled() {
        let missing = directory.appendingPathComponent("nope.vscdb")
        XCTAssertFalse(CursorHistoryProvider.isAvailable(databaseURL: missing))
        XCTAssertTrue(CursorHistoryProvider.conversations(databaseURL: missing).isEmpty)
    }

    /// Reading must never modify Cursor's database.
    func testDatabaseIsOpenedReadOnly() throws {
        try standardFixture()
        let before = try Data(contentsOf: dbURL)
        _ = CursorHistoryProvider.conversations(databaseURL: dbURL)
        let after = try Data(contentsOf: dbURL)
        XCTAssertEqual(before, after)
    }
}

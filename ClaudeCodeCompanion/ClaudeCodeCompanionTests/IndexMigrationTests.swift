import SQLite3
import XCTest
@testable import Claude_Code_Companion

/// The storage-policy migration rewrites an existing index in place. Its job is
/// to reclaim space **without** losing rows — rows for transcripts the user has
/// since deleted are the only content in the index that cannot be regenerated.
final class IndexMigrationTests: XCTestCase {

    private var directory: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("index.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixture

    /// Build an index the way an older build would have: full raw payloads for
    /// every record type, and the same message indexed twice.
    private func makeLegacyIndex(oversizedRaw: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
            CREATE TABLE indexed_files (path TEXT PRIMARY KEY, last_modified REAL NOT NULL, session_id TEXT NOT NULL, project_path TEXT NOT NULL);
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, project_path TEXT NOT NULL,
                uuid TEXT, parent_uuid TEXT, type TEXT NOT NULL, timestamp TEXT NOT NULL,
                content_text TEXT NOT NULL, content_raw TEXT NOT NULL, is_subagent INTEGER NOT NULL DEFAULT 0,
                cwd TEXT, git_branch TEXT
            );
            CREATE VIRTUAL TABLE messages_fts USING fts5(content_text, content='messages', content_rowid='id', tokenize='porter unicode61');
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        func insert(uuid: String, type: String, text: String, raw: String) {
            let sql = """
                INSERT INTO messages (session_id, project_path, uuid, type, timestamp, content_text, content_raw)
                VALUES ('s1', '/p', '\(uuid)', '\(type)', '2026-01-01T00:00:00.000Z', '\(text)', '\(raw)');
                INSERT INTO messages_fts(rowid, content_text) VALUES (last_insert_rowid(), '\(text)');
            """
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }

        insert(uuid: "chat-1", type: "user", text: "deleted transcript content", raw: #"{"type":"user"}"#)
        insert(uuid: "chat-2", type: "assistant", text: "assistant reply", raw: oversizedRaw)
        insert(uuid: "hook-1", type: "attachment", text: "hook output", raw: #"{"type":"attachment"}"#)
        insert(uuid: "queue-1", type: "queue-operation", text: "queued", raw: #"{"type":"queue-operation"}"#)
        // The same message indexed twice, as happened for a session copied into
        // a worktree folder.
        insert(uuid: "chat-1", type: "user", text: "deleted transcript content", raw: #"{"type":"user"}"#)
    }

    private func rows() throws -> [(uuid: String, type: String, rawLength: Int)] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2("file:\(dbURL.path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil), SQLITE_OK)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT uuid, type, length(content_raw) FROM messages ORDER BY id", -1, &stmt, nil), SQLITE_OK)

        var result: [(String, String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                Int(sqlite3_column_int(stmt, 2))
            ))
        }
        return result
    }

    // MARK: - Tests

    func testMigrationTrimsPayloadsWithoutLosingChatRecords() async throws {
        let oversized = String(repeating: "x", count: DatabaseManager.StoragePolicy.maximumRawBytes * 2)
        try makeLegacyIndex(oversizedRaw: oversized)

        let manager = DatabaseManager(databaseURL: dbURL)
        try await manager.open()
        try await manager.createSchema()
        await manager.close()

        let migrated = try rows()

        // Both chat records survive; the duplicate is collapsed.
        XCTAssertEqual(migrated.filter { $0.uuid == "chat-1" }.count, 1)
        XCTAssertTrue(migrated.contains { $0.uuid == "chat-2" })
        XCTAssertEqual(migrated.count, 4, "no record type may be dropped: \(migrated.map(\.uuid))")

        // Raw payloads: chat kept (capped), everything else blanked.
        let byUuid = Dictionary(migrated.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertGreaterThan(try XCTUnwrap(byUuid["chat-1"]).rawLength, 0)
        XCTAssertEqual(try XCTUnwrap(byUuid["chat-2"]).rawLength, DatabaseManager.StoragePolicy.maximumRawBytes)
        XCTAssertEqual(try XCTUnwrap(byUuid["hook-1"]).rawLength, 0)
        XCTAssertEqual(try XCTUnwrap(byUuid["queue-1"]).rawLength, 0)
    }

    /// Rewriting `content_raw` must not disturb the full-text index.
    func testSearchStillFindsMigratedContent() async throws {
        try makeLegacyIndex(oversizedRaw: #"{"type":"assistant"}"#)

        let manager = DatabaseManager(databaseURL: dbURL)
        try await manager.open()
        try await manager.createSchema()

        let results = try await manager.search(query: "deleted transcript")
        XCTAssertEqual(results.count, 1, "the surviving row must still be searchable, exactly once")
        XCTAssertEqual(results.first?.sessionId, "s1")

        let hookResults = try await manager.search(query: "hook output")
        XCTAssertEqual(hookResults.count, 1, "blanking content_raw must not remove a record from search")
        await manager.close()
    }

    /// Running twice must be a no-op — the version marker gates it.
    func testMigrationIsIdempotent() async throws {
        try makeLegacyIndex(oversizedRaw: #"{"type":"assistant"}"#)

        for _ in 0..<2 {
            let manager = DatabaseManager(databaseURL: dbURL)
            try await manager.open()
            try await manager.createSchema()
            await manager.close()
        }

        XCTAssertEqual(try rows().count, 4)
    }

    /// A brand-new index needs no migration and must come up clean.
    func testFreshIndexIsUsableImmediately() async throws {
        let manager = DatabaseManager(databaseURL: dbURL)
        try await manager.open()
        try await manager.createSchema()

        let message = ConversationMessage(
            id: "m1", sessionId: "s1", type: .user, timestamp: Date(),
            contentText: "hello from a fresh index", contentRaw: #"{"type":"user"}"#,
            parentUuid: nil, cwd: nil, gitBranch: nil
        )
        try await manager.indexMessages([message], filePath: "/tmp/a.jsonl", modificationDate: Date(), projectPath: "/p", isSubagent: false)

        let results = try await manager.search(query: "fresh index")
        XCTAssertEqual(results.count, 1)
        await manager.close()
    }

    /// Re-indexing the same records — which happens whenever a transcript's last
    /// line was still being written — must not duplicate them.
    func testReindexingSameRecordsIsIdempotent() async throws {
        let manager = DatabaseManager(databaseURL: dbURL)
        try await manager.open()
        try await manager.createSchema()

        let message = ConversationMessage(
            id: "m1", sessionId: "s1", type: .user, timestamp: Date(),
            contentText: "written twice", contentRaw: #"{"type":"user"}"#,
            parentUuid: nil, cwd: nil, gitBranch: nil
        )
        for _ in 0..<2 {
            try await manager.indexMessages(
                [message], filePath: "/tmp/a.jsonl", modificationDate: Date(),
                projectPath: "/p", isSubagent: false, agent: .claude, replaceExisting: false
            )
        }

        let results = try await manager.search(query: "written twice")
        XCTAssertEqual(results.count, 1)
        await manager.close()
    }
}

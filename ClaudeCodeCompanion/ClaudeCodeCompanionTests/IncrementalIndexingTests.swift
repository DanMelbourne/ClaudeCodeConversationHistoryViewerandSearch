import XCTest
@testable import Claude_Code_Companion

/// The append-only resume path for Claude Code transcripts: a live session file
/// grows continuously, and re-reading it whole on every append was the single
/// largest cost in an incremental index pass.
final class IncrementalIndexingTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("incremental-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func line(_ text: String, uuid: String) -> String {
        #"{"type":"user","uuid":"\#(uuid)","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((text + "\n").utf8))
    }

    func testFullParseReportsResumeOffsetAtLineBoundary() async throws {
        let url = directory.appendingPathComponent("session.jsonl")
        try write([line("one", uuid: "a"), line("two", uuid: "b")], to: url)

        let parser = JSONLParser()
        let result = try await parser.parseFile(at: url, projectPath: "p", fromByteOffset: 0)

        XCTAssertEqual(result.messages.map(\.id), ["a", "b"])
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertEqual(result.bytesConsumed, size, "a file ending in a newline is fully consumed")
    }

    func testResumeReturnsOnlyAppendedRecords() async throws {
        let url = directory.appendingPathComponent("session.jsonl")
        try write([line("one", uuid: "a")], to: url)

        let parser = JSONLParser()
        let first = try await parser.parseFile(at: url, projectPath: "p", fromByteOffset: 0)
        try append(line("two", uuid: "b"), to: url)
        let second = try await parser.parseFile(at: url, projectPath: "p", fromByteOffset: first.bytesConsumed)

        XCTAssertEqual(second.messages.map(\.id), ["b"])
    }

    /// A half-written final line must be re-read next pass, not skipped.
    func testPartialTrailingLineIsNotConsumed() async throws {
        let url = directory.appendingPathComponent("session.jsonl")
        try write([line("one", uuid: "a")], to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"user","uuid":"b","timestamp":"#.utf8))
        try handle.close()

        let parser = JSONLParser()
        let result = try await parser.parseFile(at: url, projectPath: "p", fromByteOffset: 0)

        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThan(result.bytesConsumed, size)

        // Completing the line makes it readable from the recorded offset.
        try append(#""2026-01-01T00:00:00.000Z","message":{"role":"user","content":"two"}}"#, to: url)
        let resumed = try await parser.parseFile(at: url, projectPath: "p", fromByteOffset: result.bytesConsumed)
        XCTAssertFalse(resumed.messages.isEmpty, "the completed line must be picked up on the next pass")
    }

    func testOffsetsAreStableWhenFileIsUnchanged() async throws {
        let url = directory.appendingPathComponent("session.jsonl")
        try write([line("one", uuid: "a"), line("two", uuid: "b")], to: url)

        let parser = JSONLParser()
        let first = try await parser.parseFile(at: url, projectPath: "p", fromByteOffset: 0)
        let resumed = try await parser.parseFile(at: url, projectPath: "p", fromByteOffset: first.bytesConsumed)

        XCTAssertTrue(resumed.messages.isEmpty, "an unchanged file must cost no re-indexing")
        XCTAssertEqual(resumed.bytesConsumed, first.bytesConsumed)
    }

    /// Multi-byte characters must not push the offset off a line boundary.
    func testUnicodeContentKeepsOffsetsAligned() async throws {
        let url = directory.appendingPathComponent("session.jsonl")
        try write([line("héllo — ✅", uuid: "a")], to: url)

        let parser = JSONLParser()
        let first = try await parser.parseFile(at: url, projectPath: "p", fromByteOffset: 0)
        try append(line("second", uuid: "b"), to: url)
        let second = try await parser.parseFile(at: url, projectPath: "p", fromByteOffset: first.bytesConsumed)

        XCTAssertEqual(second.messages.map(\.id), ["b"])
    }
}

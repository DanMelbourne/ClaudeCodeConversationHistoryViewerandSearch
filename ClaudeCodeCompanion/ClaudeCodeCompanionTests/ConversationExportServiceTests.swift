import XCTest
@testable import Claude_Code_Companion

final class ConversationExportServiceTests: XCTestCase {
    func testExportOrdersSessionsFromOldestToNewest() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldest = directory.appendingPathComponent("oldest.jsonl")
        let newest = directory.appendingPathComponent("newest.jsonl")
        try makeTranscript(
            at: oldest,
            content: "Beginning of the oldest conversation",
            timestamp: "2026-07-17T12:00:00Z"
        )
        try makeTranscript(
            at: newest,
            content: "Beginning of the newest conversation",
            timestamp: "2026-07-18T12:00:00Z"
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: oldest.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: newest.path
        )

        let destination = directory.appendingPathComponent("history.txt")
        _ = try ConversationExportService.exportProjectConversations(
            from: makeProject(at: directory),
            to: destination
        )
        let output = try String(contentsOf: destination, encoding: .utf8)

        let oldestRange = try XCTUnwrap(output.range(of: "Beginning of the oldest conversation"))
        let newestRange = try XCTUnwrap(output.range(of: "Beginning of the newest conversation"))
        XCTAssertLessThan(oldestRange.lowerBound, newestRange.lowerBound)
    }

    func testExportFailsWhenProjectHasNoInteractiveChatMessages() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = """
        {"type":"system","uuid":"system-1","timestamp":"2026-07-21T00:00:00Z","message":{"content":"Hidden system message"}}
        {"type":"queue-operation","uuid":"queue-1","timestamp":"2026-07-21T00:00:01Z","message":{"content":"Hidden queue event"}}
        """
        try transcript.write(to: directory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try ConversationExportService.exportProjectConversations(
                from: makeProject(at: directory),
                to: directory.appendingPathComponent("history.txt")
            )
        ) { error in
            XCTAssertEqual((error as? ConversationExportService.ExportError)?.errorDescription, "The selected project has no user or Claude messages to export.")
        }
    }

    func testExportIncludesOnlyMessagesShownInInteractiveChat() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = """
        {"type":"user","uuid":"user-1","timestamp":"2026-07-21T00:00:00Z","message":{"content":"Visible user message"}}
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-07-21T00:00:01Z","message":{"content":"Visible Claude message"}}
        {"type":"system","uuid":"system-1","timestamp":"2026-07-21T00:00:02Z","message":{"content":"Hidden system message"}}
        {"type":"queue-operation","uuid":"queue-1","timestamp":"2026-07-21T00:00:03Z","message":{"content":"Hidden queue event"}}
        """
        try transcript.write(to: directory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let destination = directory.appendingPathComponent("history.txt")
        let result = try ConversationExportService.exportProjectConversations(
            from: makeProject(at: directory),
            to: destination
        )
        let output = try String(contentsOf: destination, encoding: .utf8)

        XCTAssertTrue(output.contains("Visible user message"))
        XCTAssertTrue(output.contains("Visible Claude message"))
        XCTAssertFalse(output.contains("Hidden system message"))
        XCTAssertFalse(output.contains("Hidden queue event"))
        XCTAssertEqual(result.messageCount, 2)
    }

    func testExportSelectedProjectConversationsExcludesOtherProjects() throws {
        let selectedDirectory = try makeTemporaryDirectory()
        let otherDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: selectedDirectory)
            try? FileManager.default.removeItem(at: otherDirectory)
        }

        try makeTranscript(at: selectedDirectory.appendingPathComponent("selected.jsonl"), content: "Selected project")
        try makeTranscript(at: otherDirectory.appendingPathComponent("other.jsonl"), content: "Other project")

        let destination = selectedDirectory.appendingPathComponent("history.txt")
        let result = try ConversationExportService.exportProjectConversations(
            from: makeProject(at: selectedDirectory, name: "Selected"),
            to: destination
        )
        let output = try String(contentsOf: destination, encoding: .utf8)

        XCTAssertEqual(result.projectCount, 1)
        XCTAssertEqual(result.conversationCount, 1)
        XCTAssertEqual(result.messageCount, 1)
        XCTAssertTrue(output.contains("Selected project"))
        XCTAssertFalse(output.contains("Other project"))
        XCTAssertFalse(output.contains("# Other"))
    }

    func testExportAllConversationsIncludesNestedSessions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nestedDirectory = directory.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try makeTranscript(at: directory.appendingPathComponent("parent.jsonl"), content: "Parent")
        try makeTranscript(at: nestedDirectory.appendingPathComponent("child.jsonl"), content: "Child")

        let destination = directory.appendingPathComponent("history.txt")
        let result = try ConversationExportService.exportAllConversations(
            from: [makeProject(at: directory)],
            to: destination
        )
        let output = try String(contentsOf: destination, encoding: .utf8)

        XCTAssertEqual(result.conversationCount, 2)
        XCTAssertTrue(output.contains("Parent"))
        XCTAssertTrue(output.contains("Child"))
    }

    func testExportAllConversationsPreservesUTF8AcrossReadBoundary() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let chunkSize = 256 * 1024
        let jsonPrefix = "{\"type\":\"user\",\"uuid\":\"user-1\",\"timestamp\":\"2026-07-21T00:00:00Z\",\"message\":{\"content\":\""
        let filler = String(repeating: "a", count: chunkSize - 1 - jsonPrefix.utf8.count)
        let transcript = jsonPrefix + filler + "é\"}}\n"
        try transcript.write(to: directory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let destination = directory.appendingPathComponent("history.txt")
        _ = try ConversationExportService.exportAllConversations(
            from: [makeProject(at: directory)],
            to: destination
        )

        let output = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(output.contains(filler.suffix(20) + "é"))
    }

    func testExportAllConversationsStreamsJSONLIntoOneTextFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = directory.appendingPathComponent("session.jsonl")
        let transcript = """
        {"type":"user","uuid":"user-1","timestamp":"2026-07-21T00:00:00Z","message":{"content":"Hello"}}
        {"type":"assistant","uuid":"assistant-1","timestamp":"2026-07-21T00:00:01Z","message":{"content":"Hi there"}}
        """
        try transcript.write(to: session, atomically: true, encoding: .utf8)

        let destination = directory.appendingPathComponent("history.txt")

        let result = try ConversationExportService.exportAllConversations(
            from: [makeProject(at: directory)],
            to: destination
        )
        let output = try String(contentsOf: destination, encoding: .utf8)

        XCTAssertEqual(result.projectCount, 1)
        XCTAssertEqual(result.conversationCount, 1)
        XCTAssertTrue(output.contains("# Project"))
        XCTAssertTrue(output.contains("[2026-07-21T00:00:00Z] User\nHello"))
        XCTAssertTrue(output.contains("[2026-07-21T00:00:01Z] Claude\nHi there"))
    }

    func testConsolidatedTextKeepsProjectsSessionsAndMessagesInProvidedOrder() {
        let text = ConversationExportService.consolidatedText(
            exportedAt: Date(timeIntervalSince1970: 0),
            conversations: [
                .init(
                    projectName: "Alpha",
                    sessionTitle: "First session",
                    sessionDate: Date(timeIntervalSince1970: 60),
                    messages: [
                        .init(timestamp: Date(timeIntervalSince1970: 61), role: "User", content: "Hello"),
                        .init(timestamp: Date(timeIntervalSince1970: 62), role: "Claude", content: "Hi there")
                    ]
                ),
                .init(
                    projectName: "Beta",
                    sessionTitle: "Second session",
                    sessionDate: nil,
                    messages: []
                )
            ]
        )

        XCTAssertEqual(
            text,
            """
            Claude Code Conversation History
            Exported: 1970-01-01T00:00:00Z

            # Alpha

            ## First session — 1970-01-01T00:01:00Z

            [1970-01-01T00:01:01Z] User
            Hello

            [1970-01-01T00:01:02Z] Claude
            Hi there

            # Beta

            ## Second session

            """
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeProject(at directory: URL, name: String = "Project") -> Project {
        Project(
            id: "project",
            displayName: name,
            path: directory,
            additionalPaths: [],
            sessionCount: 1,
            lastActivityDate: nil
        )
    }

    private func makeTranscript(
        at url: URL,
        content: String,
        timestamp: String = "2026-07-21T00:00:00Z"
    ) throws {
        let transcript = "{\"type\":\"user\",\"uuid\":\"user-1\",\"timestamp\":\"\(timestamp)\",\"message\":{\"content\":\"\(content)\"}}\n"
        try transcript.write(to: url, atomically: true, encoding: .utf8)
    }
}

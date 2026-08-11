import XCTest
@testable import Claude_Code_Companion

@MainActor
final class AppViewModelTests: XCTestCase {
    func testMergingIndexedSessionsNeverHidesFilesystemSessions() {
        let filesystemSession = ConversationSession(
            id: "claude-session",
            projectId: "-Users-dan-Code-ScreenshotTray",
            filePath: URL(fileURLWithPath: "/tmp/claude-session.jsonl"),
            firstUserMessage: "Existing Claude conversation",
            timestamp: Date(timeIntervalSince1970: 2),
            messageCount: 12,
            isSubagent: false
        )

        let merged = AppViewModel.mergeSessions(
            projectId: "-Users-dan-Code-ScreenshotTray",
            filesystemSessions: [filesystemSession],
            indexedAgentSessions: []
        )

        XCTAssertEqual(merged.map(\.id), ["claude-session"])
        XCTAssertEqual(merged.first?.firstUserMessage, "Existing Claude conversation")
    }

    func testMergingIndexedSessionsRetagsAndSortsAgentSessions() {
        let filesystemSession = ConversationSession(
            id: "claude-session",
            projectId: "-Users-dan-Code-ScreenshotTray",
            filePath: URL(fileURLWithPath: "/tmp/claude-session.jsonl"),
            firstUserMessage: "Claude",
            timestamp: Date(timeIntervalSince1970: 1),
            messageCount: 2,
            isSubagent: false
        )
        let indexedSession = ConversationSession(
            id: "codex-session",
            projectId: "database-project-path",
            filePath: URL(fileURLWithPath: "/tmp/rollout.jsonl"),
            firstUserMessage: "Codex",
            timestamp: Date(timeIntervalSince1970: 3),
            messageCount: 4,
            isSubagent: false,
            agent: .codex
        )

        let merged = AppViewModel.mergeSessions(
            projectId: "-Users-dan-Code-ScreenshotTray",
            filesystemSessions: [filesystemSession],
            indexedAgentSessions: [indexedSession]
        )

        XCTAssertEqual(merged.map(\.id), ["codex-session", "claude-session"])
        XCTAssertEqual(merged.map(\.projectId), [
            "-Users-dan-Code-ScreenshotTray",
            "-Users-dan-Code-ScreenshotTray"
        ])
        XCTAssertEqual(merged.map(\.agent), [.codex, .claude])
    }

    func testCachedReconstructionIncludesOnlyInteractiveMessages() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let messages = [
            makeMessage(id: "user", type: .user, content: "Remember this", timestamp: timestamp),
            makeMessage(id: "queue", type: .queueOperation, content: "Internal queue event", timestamp: timestamp.addingTimeInterval(1)),
            makeMessage(id: "assistant", type: .assistant, content: "Recovered context", timestamp: timestamp.addingTimeInterval(2))
        ]

        let reconstructed = AppViewModel.cachedParsedMessages(from: messages)

        XCTAssertEqual(reconstructed.map(\.id), ["user", "assistant"])
        XCTAssertEqual(reconstructed.map(\.timestamp), [timestamp, timestamp.addingTimeInterval(2)])
        XCTAssertEqual(reconstructed[0].blocks, [.text("Remember this")])
        XCTAssertEqual(reconstructed[1].rawJSON, "{\"type\":\"assistant\",\"message\":{\"content\":\"Recovered context\"}}")
    }

    func testNavigateToSearchResultReportsWhenOriginalTranscriptIsMissing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = Project(
            id: "project",
            displayName: "Project",
            path: directory,
            additionalPaths: [],
            sessionCount: 0,
            lastActivityDate: nil
        )
        let result = SearchResult(
            id: 1,
            sessionId: "missing-session",
            projectPath: directory.path,
            messageUuid: "message-1",
            messageType: "user",
            timestamp: .now,
            snippet: "Cached snippet",
            fullText: "Cached snippet",
            contextBefore: "",
            contextAfter: ""
        )
        let viewModel = AppViewModel()
        viewModel.projects = [project]
        viewModel.searchResults = [result]
        viewModel.detailDestination = .searchResults

        viewModel.navigateToSearchResult(result)

        let message = try await waitForNavigationError(in: viewModel)
        XCTAssertEqual(message, "The original conversation file is no longer available on disk.")
        XCTAssertEqual(viewModel.detailDestination, .searchResults)
        XCTAssertNil(viewModel.selectedProject)
        XCTAssertNil(viewModel.selectedSession)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeMessage(
        id: String,
        type: ConversationMessage.MessageType,
        content: String,
        timestamp: Date
    ) -> ConversationMessage {
        ConversationMessage(
            id: id,
            sessionId: "session",
            type: type,
            timestamp: timestamp,
            contentText: content,
            contentRaw: "{\"type\":\"\(type.rawValue)\",\"message\":{\"content\":\"\(content)\"}}",
            parentUuid: nil,
            cwd: nil,
            gitBranch: nil
        )
    }

    private func waitForNavigationError(in viewModel: AppViewModel) async throws -> String {
        for _ in 0..<100 {
            if let message = viewModel.navigationErrorMessage {
                return message
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Navigation did not report the missing transcript within one second.")
        return ""
    }
}

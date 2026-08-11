import XCTest
@testable import Claude_Code_Companion

/// Covers the merge of Codex/Cursor projects into the filesystem project list
/// and the per-agent switches.
final class AgentIndexingTests: XCTestCase {

    private func project(
        id: String,
        path: String,
        sessions: Int,
        date: Date?,
        agents: Set<AgentKind>
    ) -> Project {
        Project(
            id: id,
            displayName: id,
            path: URL(fileURLWithPath: path),
            additionalPaths: [],
            sessionCount: sessions,
            lastActivityDate: date,
            agents: agents
        )
    }

    private func claudeProjectPath(_ folder: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(folder)").path
    }

    // MARK: - Project merge

    func testSameFolderMergesIntoOneProject() {
        let folder = "-Users-dan-Code-ScreenshotTray"
        let older = Date(timeIntervalSince1970: 1_780_000_000)
        let newer = Date(timeIntervalSince1970: 1_781_000_000)

        let fileProject = project(
            id: folder, path: claudeProjectPath(folder), sessions: 4, date: older, agents: [.claude]
        )
        let codexProject = project(
            id: claudeProjectPath(folder), path: claudeProjectPath(folder), sessions: 3, date: newer, agents: [.codex]
        )

        let merged = AppViewModel.merge(agentProjects: [codexProject], into: [fileProject])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sessionCount, 7)
        XCTAssertEqual(merged[0].agents, [.claude, .codex])
        XCTAssertEqual(merged[0].lastActivityDate, newer, "the newest activity across agents must win")
        XCTAssertEqual(merged[0].id, folder, "the sidebar id must stay the folder name")
    }

    func testAgentOnlyProjectIsAdded() {
        let folder = "-Users-dan-Code-CursorOnly"
        let cursorProject = project(
            id: claudeProjectPath(folder),
            path: claudeProjectPath(folder),
            sessions: 2,
            date: Date(timeIntervalSince1970: 1_780_000_000),
            agents: [.cursor]
        )

        let merged = AppViewModel.merge(agentProjects: [cursorProject], into: [])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, folder)
        XCTAssertEqual(merged[0].agents, [.cursor])
        XCTAssertEqual(merged[0].displayName, "CursorOnly")
    }

    /// Merging must never drop a Claude project, even with no agent history.
    func testEmptyAgentListLeavesFileProjectsIntact() {
        let folder = "-Users-dan-Code-Solo"
        let fileProject = project(
            id: folder, path: claudeProjectPath(folder), sessions: 1, date: nil, agents: [.claude]
        )

        let merged = AppViewModel.merge(agentProjects: [], into: [fileProject])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sessionCount, 1)
        XCTAssertEqual(merged[0].agents, [.claude])
    }

    /// A Codex session run inside a git worktree must land on the parent
    /// project, not spawn a second row.
    func testWorktreeAgentProjectMergesIntoParent() {
        let folder = "-Users-dan-Code-ScreenshotTray"
        let worktree = "\(folder)--claude-worktrees-wf-1234"

        let fileProject = project(
            id: folder, path: claudeProjectPath(folder), sessions: 5, date: nil, agents: [.claude]
        )
        let codexWorktree = project(
            id: claudeProjectPath(worktree), path: claudeProjectPath(worktree), sessions: 2, date: nil, agents: [.codex]
        )

        let merged = AppViewModel.merge(agentProjects: [codexWorktree], into: [fileProject])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, folder)
        XCTAssertEqual(merged[0].sessionCount, 7)
        XCTAssertEqual(merged[0].agents, [.claude, .codex])
    }

    func testMergeIsIdempotentForRepeatedLoads() {
        let folder = "-Users-dan-Code-Repeat"
        let fileProject = project(
            id: folder, path: claudeProjectPath(folder), sessions: 2, date: nil, agents: [.claude]
        )
        let agentProject = project(
            id: claudeProjectPath(folder), path: claudeProjectPath(folder), sessions: 1, date: nil, agents: [.codex]
        )

        let first = AppViewModel.merge(agentProjects: [agentProject], into: [fileProject])
        let second = AppViewModel.merge(agentProjects: [agentProject], into: [fileProject])

        XCTAssertEqual(first.map(\.sessionCount), second.map(\.sessionCount))
        XCTAssertEqual(first[0].sessionCount, 3)
    }

    // MARK: - Agent switches

    func testAgentDefaultsToEnabledAndPersistsChanges() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agent-tests-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        XCTAssertTrue(AgentKind.isEnabled(.codex, defaults: defaults))

        AgentKind.setEnabled(false, for: .codex, defaults: defaults)
        XCTAssertFalse(AgentKind.isEnabled(.codex, defaults: defaults))

        AgentKind.setEnabled(true, for: .codex, defaults: defaults)
        XCTAssertTrue(AgentKind.isEnabled(.codex, defaults: defaults))
    }

    func testClaudeCannotBeDisabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agent-tests-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        AgentKind.setEnabled(false, for: .claude, defaults: defaults)
        XCTAssertTrue(AgentKind.isEnabled(.claude, defaults: defaults))
    }

    // MARK: - Watcher paths

    func testCodexDirectoryIsWatchedWhenEnabled() {
        let home = URL(fileURLWithPath: "/tmp/agent-home", isDirectory: true)
        let paths = AppViewModel.watcherPaths(homeDirectory: home, externalSources: [])

        XCTAssertTrue(
            paths.contains { $0.path.hasSuffix(".codex/sessions") },
            "Codex rollouts must be watched so new sessions appear live"
        )
        XCTAssertTrue(paths.contains { $0.path.hasSuffix(".claude/projects") })
    }

    // MARK: - Reveal in Finder

    /// A Codex/Cursor-only project has no `~/.claude/projects` folder, so
    /// Reveal must target the working directory the agents actually ran in.
    func testRevealPrefersExistingWorkingDirectory() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reveal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        var agentOnly = project(
            id: "-tmp-missing", path: "/nonexistent/-tmp-missing", sessions: 1, date: nil, agents: [.cursor]
        )
        agentOnly.workingDirectory = workingDirectory.path

        XCTAssertEqual(agentOnly.revealTarget?.path, workingDirectory.path)
    }

    func testRevealFallsBackToTranscriptFolderThenNil() {
        var missing = project(
            id: "-tmp-missing", path: "/nonexistent/-tmp-missing", sessions: 1, date: nil, agents: [.codex]
        )
        XCTAssertNil(missing.revealTarget, "nothing on disk means the menu item is disabled, not broken")

        missing.workingDirectory = "/also/not/here"
        XCTAssertNil(missing.revealTarget)

        let existing = project(
            id: "tmp", path: FileManager.default.temporaryDirectory.path, sessions: 1, date: nil, agents: [.claude]
        )
        XCTAssertEqual(
            existing.revealTarget?.standardizedFileURL.path,
            FileManager.default.temporaryDirectory.standardizedFileURL.path
        )
    }

    // MARK: - Storage policy

    /// `content_raw` only feeds the cached-copy view, which renders user and
    /// assistant records; storing it for anything else wasted 800 MB.
    func testRawPayloadKeptOnlyForChatRecords() {
        func message(_ type: ConversationMessage.MessageType, raw: String) -> ConversationMessage {
            ConversationMessage(
                id: "m", sessionId: "s", type: type, timestamp: Date(),
                contentText: "text", contentRaw: raw, parentUuid: nil, cwd: nil, gitBranch: nil
            )
        }

        XCTAssertEqual(DatabaseManager.StoragePolicy.rawPayload(for: message(.user, raw: "{\"a\":1}")), "{\"a\":1}")
        XCTAssertEqual(DatabaseManager.StoragePolicy.rawPayload(for: message(.assistant, raw: "{\"a\":1}")), "{\"a\":1}")
        XCTAssertEqual(DatabaseManager.StoragePolicy.rawPayload(for: message(.attachment, raw: "{\"a\":1}")), "")
        XCTAssertEqual(DatabaseManager.StoragePolicy.rawPayload(for: message(.queueOperation, raw: "{\"a\":1}")), "")
    }

    func testOversizedRawPayloadIsCapped() {
        let huge = String(repeating: "x", count: DatabaseManager.StoragePolicy.maximumRawBytes * 2)
        let message = ConversationMessage(
            id: "m", sessionId: "s", type: .assistant, timestamp: Date(),
            contentText: huge, contentRaw: huge, parentUuid: nil, cwd: nil, gitBranch: nil
        )

        let stored = DatabaseManager.StoragePolicy.rawPayload(for: message)
        XCTAssertEqual(stored.count, DatabaseManager.StoragePolicy.maximumRawBytes)
        XCTAssertEqual(message.contentText.count, huge.count, "searchable text is never trimmed")
    }

    // MARK: - Message dispatch

    func testCursorSessionsAreNotTreatedAsFiles() {
        let session = ConversationSession(
            id: "c1",
            projectId: "p",
            filePath: URL(fileURLWithPath: "/nonexistent/state.vscdb"),
            firstUserMessage: nil,
            timestamp: nil,
            messageCount: 1,
            isSubagent: false,
            agent: .cursor
        )
        XCTAssertEqual(session.agent, .cursor)
        // A missing path must not be interpreted as a missing transcript for
        // Cursor: the messages come from its database instead.
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.filePath.path))
    }

    func testParsedMessagesSkipEmptyBlocks() {
        let message = ConversationMessage(
            id: "m1",
            sessionId: "s1",
            type: .assistant,
            timestamp: Date(),
            contentText: "",
            contentRaw: #"{"type":"assistant","message":{"role":"assistant","content":[]}}"#,
            parentUuid: nil,
            cwd: nil,
            gitBranch: nil,
            agent: .codex
        )
        XCTAssertTrue(AppViewModel.parsedMessages(from: [message]).isEmpty)
    }
}

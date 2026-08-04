import XCTest
@testable import Claude_Code_Companion

final class FileWatcherTests: XCTestCase {
    func testReportsWritesInNestedConversationDirectories() throws {
        let directory = try makeTemporaryDirectory()
        let nestedDirectory = directory.appendingPathComponent("project/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let changeObserved = expectation(description: "nested transcript write observed")
        let watcher = FileWatcher(path: directory) {
            changeObserved.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        try "{\"type\":\"user\"}\n".write(
            to: nestedDirectory.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        wait(for: [changeObserved], timeout: 4)
    }

    func testWatcherPathsIncludeLocalAndEnabledAccessibleExternalRootsOnce() throws {
        let home = try makeTemporaryDirectory()
        let external = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/projects", isDirectory: true),
            withIntermediateDirectories: true
        )

        let enabled = ConversationSource(name: "External", path: external.path)
        var duplicate = ConversationSource(name: "Duplicate", path: external.path)
        var disabled = ConversationSource(name: "Disabled", path: external.path)
        duplicate.isEnabled = true
        disabled.isEnabled = false

        let paths = AppViewModel.watcherPaths(
            homeDirectory: home,
            externalSources: [enabled, duplicate, disabled]
        )

        // Codex rollouts are watched alongside the Claude projects folder.
        XCTAssertEqual(
            Set(paths.map(\.standardizedFileURL.path)),
            [
                home.appendingPathComponent(".claude/projects").standardizedFileURL.path,
                home.appendingPathComponent(".codex/sessions").standardizedFileURL.path,
                external.standardizedFileURL.path
            ]
        )
    }

    func testCollectsOnlyNestedJSONLConversationFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("project/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let transcript = nested.appendingPathComponent("session.jsonl")
        let ignored = nested.appendingPathComponent("notes.txt")
        try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)
        try "ignore".write(to: ignored, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ConversationStore.collectJSONLFiles(under: directory).map { $0.resolvingSymlinksInPath() },
            [transcript.resolvingSymlinksInPath()]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

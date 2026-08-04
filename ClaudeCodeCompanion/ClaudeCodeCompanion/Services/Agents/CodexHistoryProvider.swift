import Foundation

/// Reads Codex CLI / Codex Desktop conversation history.
///
/// Codex writes one JSONL "rollout" per session under
/// `~/.codex/sessions/<yyyy>/<MM>/<dd>/rollout-<iso>-<uuid>.jsonl`.
/// The first line is a `session_meta` record carrying the session id, the
/// working directory and git info; every later line is either a
/// `response_item` (the model transcript) or an `event_msg` (UI events that
/// duplicate the transcript, so they are skipped).
enum CodexHistoryProvider {

    /// One parsed rollout file.
    struct Session {
        let id: String
        let fileURL: URL
        let workingDirectory: String?
        let gitBranch: String?
        let messages: [ConversationMessage]
        let modificationDate: Date?

        /// The project row this session belongs to.
        var projectPath: String? {
            guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
            return ProjectPathEncoder.projectPath(for: workingDirectory)
        }

        var firstUserMessage: String? {
            messages.first(where: { $0.type == .user && !$0.contentText.isEmpty })
                .map { String($0.contentText.prefix(200)) }
        }

        var lastActivity: Date? {
            messages.last?.timestamp ?? modificationDate
        }
    }

    /// Metadata read from the header line only — cheap enough to run over every
    /// rollout when building the project list.
    struct SessionHeader {
        let id: String
        let fileURL: URL
        let workingDirectory: String
        let modificationDate: Date?
    }

    static let rootDirectory = AgentKind.codex.defaultHistoryLocation

    // MARK: - Discovery

    /// All rollout files under a Codex sessions root, newest first.
    nonisolated static func rolloutFiles(under root: URL = rootDirectory) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    /// Read only the `session_meta` header of a rollout.
    nonisolated static func readHeader(at url: URL) -> SessionHeader? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { handle.closeFile() }

        // Session meta is the first line; 128 KB is far beyond its real size
        // even with the full base instructions embedded.
        guard let data = try? handle.read(upToCount: 128 * 1024),
              let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first,
              let json = jsonObject(String(firstLine)),
              json["type"] as? String == "session_meta",
              let payload = json["payload"] as? [String: Any] else { return nil }

        let cwd = payload["cwd"] as? String ?? ""
        guard !cwd.isEmpty else { return nil }

        let id = payload["session_id"] as? String
            ?? payload["id"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        let modDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        return SessionHeader(id: id, fileURL: url, workingDirectory: cwd, modificationDate: modDate ?? nil)
    }

    // MARK: - Parsing

    /// Codex rollouts are unbounded — long automation runs reach a gigabyte or
    /// more. Indexing streams the whole file in batches so search covers every
    /// message; only the on-screen transcript is windowed, because no view can
    /// usefully render a hundred thousand messages.
    static let indexingBatchSize = 2_000
    static let displayHeadMessages = 2_000
    static let displayTailMessages = 2_000

    /// Metadata from a rollout's header, available before any message batch.
    struct SessionInfo {
        let id: String
        let fileURL: URL
        let workingDirectory: String?
        let gitBranch: String?
        let modificationDate: Date?

        var projectPath: String? {
            guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
            return ProjectPathEncoder.projectPath(for: workingDirectory)
        }
    }

    /// Stream a rollout, handing messages over in batches so neither indexing
    /// nor display ever holds a whole multi-gigabyte transcript in memory.
    /// Returns nil when the file yields no messages at all.
    /// - fromByteOffset: resume point for an appended rollout. The header is
    ///   re-read first so the session id and working directory are known.
    @discardableResult
    nonisolated static func stream(
        at url: URL,
        batchSize: Int = indexingBatchSize,
        fromByteOffset offset: Int = 0,
        onBatch: ([ConversationMessage], SessionInfo, Int) -> Void
    ) -> SessionInfo? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { handle.closeFile() }

        var sessionId = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        var gitBranch: String?
        var batch: [ConversationMessage] = []
        var emitted = 0
        var consumed = offset
        let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil

        // Resuming mid-file still needs the header's session id and cwd.
        if offset > 0 {
            if let header = readHeader(at: url) {
                sessionId = header.id
                cwd = header.workingDirectory
            }
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        }

        func info() -> SessionInfo {
            SessionInfo(
                id: sessionId,
                fileURL: url,
                workingDirectory: cwd,
                gitBranch: gitBranch,
                modificationDate: modificationDate
            )
        }

        func flush() {
            guard !batch.isEmpty else { return }
            emitted += batch.count
            onBatch(batch, info(), consumed)
            batch.removeAll(keepingCapacity: true)
        }

        var leftover = ""
        while true {
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            guard let chunkString = String(data: chunk, encoding: .utf8) else { continue }
            leftover += chunkString
            var lines = leftover.components(separatedBy: "\n")
            leftover = lines.removeLast()
            for line in lines {
                // The line's own offset is its identity: stable across re-reads
                // and unique when a later pass resumes mid-file.
                let lineOffset = consumed
                consumed += line.utf8.count + 1
                consume(
                    line: line,
                    lineOffset: lineOffset,
                    sessionId: &sessionId,
                    cwd: &cwd,
                    gitBranch: &gitBranch,
                    into: &batch
                )
                if batch.count >= batchSize { flush() }
            }
        }
        // A trailing line with no newline is incomplete; parse it but leave the
        // resume point before it.
        consume(
            line: leftover,
            lineOffset: consumed,
            sessionId: &sessionId,
            cwd: &cwd,
            gitBranch: &gitBranch,
            into: &batch
        )
        flush()

        return emitted > 0 ? info() : nil
    }

    /// Parse a rollout for display: the opening and closing stretches of the
    /// conversation, with an explicit notice when the middle was left out.
    nonisolated static func parseSession(
        at url: URL,
        headLimit: Int = displayHeadMessages,
        tailLimit: Int = displayTailMessages
    ) -> Session? {
        var head: [ConversationMessage] = []
        var tail: [ConversationMessage] = []
        var omitted = 0

        guard let info = stream(at: url, batchSize: 500, onBatch: { batch, _, _ in
            for message in batch {
                if head.count < headLimit {
                    head.append(message)
                    continue
                }
                tail.append(message)
                if tail.count > tailLimit {
                    tail.removeFirst()
                    omitted += 1
                }
            }
        }) else { return nil }

        var messages = head
        if omitted > 0, let notice = AgentMessageBuilder.message(
            type: .system,
            uuid: "\(info.id)-omitted",
            sessionId: info.id,
            timestamp: tail.first?.timestamp ?? head.last?.timestamp ?? Date.distantPast,
            blocks: [AgentMessageBuilder.textBlock(
                "[\(omitted) messages from the middle of this Codex session are not shown here. They are all searchable.]"
            )],
            cwd: info.workingDirectory,
            gitBranch: info.gitBranch,
            agent: .codex
        ) {
            messages.append(notice)
        }
        messages.append(contentsOf: tail)

        return Session(
            id: info.id,
            fileURL: url,
            workingDirectory: info.workingDirectory,
            gitBranch: info.gitBranch,
            messages: messages,
            modificationDate: info.modificationDate
        )
    }

    // MARK: - Line handling

    private nonisolated static func consume(
        line: String,
        lineOffset: Int,
        sessionId: inout String,
        cwd: inout String?,
        gitBranch: inout String?,
        into messages: inout [ConversationMessage]
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let json = jsonObject(trimmed) else { return }

        let timestamp = (json["timestamp"] as? String).map(JSONLParser.parseTimestamp) ?? Date.distantPast
        let recordType = json["type"] as? String ?? ""
        let payload = json["payload"] as? [String: Any] ?? [:]

        switch recordType {
        case "session_meta":
            if let id = payload["session_id"] as? String ?? payload["id"] as? String { sessionId = id }
            if let dir = payload["cwd"] as? String, !dir.isEmpty { cwd = dir }
            if let git = payload["git"] as? [String: Any], let branch = git["branch"] as? String {
                gitBranch = branch
            }

        case "turn_context":
            if cwd == nil, let dir = payload["cwd"] as? String, !dir.isEmpty { cwd = dir }

        case "response_item":
            if let message = message(
                fromResponseItem: payload,
                timestamp: timestamp,
                uuid: "\(sessionId)@\(lineOffset)",
                sessionId: sessionId,
                cwd: cwd,
                gitBranch: gitBranch
            ) {
                messages.append(message)
            }

        default:
            // event_msg records mirror response_item content for the live UI.
            break
        }
    }

    /// Map one Codex `response_item` payload onto a Claude-shaped message.
    nonisolated static func message(
        fromResponseItem payload: [String: Any],
        timestamp: Date,
        uuid: String,
        sessionId: String,
        cwd: String?,
        gitBranch: String?
    ) -> ConversationMessage? {
        let build: (ConversationMessage.MessageType, [[String: Any]]) -> ConversationMessage? = { type, blocks in
            AgentMessageBuilder.message(
                type: type,
                uuid: uuid,
                sessionId: sessionId,
                timestamp: timestamp,
                blocks: blocks,
                cwd: cwd,
                gitBranch: gitBranch,
                agent: .codex
            )
        }

        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String ?? "assistant"
            let text = textOfContent(payload["content"])
            guard !text.isEmpty else { return nil }
            switch role {
            case "user":
                return build(.user, [AgentMessageBuilder.textBlock(text)])
            case "assistant":
                return build(.assistant, [AgentMessageBuilder.textBlock(text)])
            default:
                // developer / system prompts — indexed but hidden by default.
                return build(.system, [AgentMessageBuilder.textBlock(text)])
            }

        case "reasoning":
            var parts: [String] = []
            if let summary = payload["summary"] as? [[String: Any]] {
                parts.append(contentsOf: summary.compactMap { $0["text"] as? String })
            }
            let inline = textOfContent(payload["content"])
            if !inline.isEmpty { parts.append(inline) }
            let text = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !text.isEmpty else { return nil }
            return build(.assistant, [AgentMessageBuilder.thinkingBlock(text)])

        case "function_call", "custom_tool_call", "local_shell_call":
            let name = payload["name"] as? String ?? "tool"
            let rawInput = payload["arguments"] ?? payload["input"] ?? payload["action"]
            let input = toolInput(rawInput)
            return build(.assistant, [AgentMessageBuilder.toolUseBlock(name: name, input: input)])

        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            let text = AgentMessageBuilder.truncated(
                AgentMessageBuilder.flattenedText(payload["output"])
            )
            guard !text.isEmpty else { return nil }
            return build(.assistant, [AgentMessageBuilder.toolResultBlock(text)])

        case "tool_search_call":
            let query = AgentMessageBuilder.flattenedText(payload["query"] ?? payload["input"])
            return build(.assistant, [
                AgentMessageBuilder.toolUseBlock(name: "tool_search", input: ["query": query])
            ])

        case "tool_search_output":
            let text = AgentMessageBuilder.truncated(
                AgentMessageBuilder.flattenedText(payload["output"] ?? payload["results"])
            )
            guard !text.isEmpty else { return nil }
            return build(.assistant, [AgentMessageBuilder.toolResultBlock(text)])

        default:
            return nil
        }
    }

    // MARK: - Helpers

    /// Codex content arrays use `input_text` / `output_text` item types.
    private nonisolated static func textOfContent(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let items = content as? [[String: Any]] else { return "" }
        return items.compactMap { item -> String? in
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            return text
        }.joined(separator: "\n")
    }

    /// Tool arguments arrive as a JSON string; decode so the inspector can
    /// pretty-print them the way it does for Claude tool calls.
    private nonisolated static func toolInput(_ raw: Any?) -> Any {
        if let string = raw as? String {
            if let decoded = jsonObject(string) { return decoded }
            return ["input": string]
        }
        if let dict = raw as? [String: Any] { return dict }
        if let array = raw as? [Any] { return ["input": AgentMessageBuilder.jsonString(array)] }
        return [String: Any]()
    }

    private nonisolated static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

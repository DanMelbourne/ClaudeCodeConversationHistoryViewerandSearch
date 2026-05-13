import Foundation

enum DBSearchScope {
    case allProjects
    case project(String)
    case session(String)
}

@MainActor
@Observable
class SearchEngine {
    var results: [SearchResult] = []
    var isSearching = false
    var currentMatchIndex: Int = 0
    var contextLines: Int = 3

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func search(query: String, scope: DBSearchScope, useIndex: Bool) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            currentMatchIndex = 0
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            if useIndex {
                results = try await ftsSearch(query: trimmed, scope: scope)
            } else {
                let scopePath = resolveScopePath(scope)
                results = try await rawGrep(query: trimmed, scopePath: scopePath)
            }
            currentMatchIndex = 0
        } catch {
            results = []
            currentMatchIndex = 0
        }
    }

    private func ftsSearch(query: String, scope: DBSearchScope) async throws -> [SearchResult] {
        switch scope {
        case .allProjects:
            return try await db.search(query: query)
        case .project(let path):
            return try await db.search(query: query, projectPath: path)
        case .session(let sessionId):
            return try await db.search(query: query, sessionId: sessionId)
        }
    }

    private func rawGrep(query: String, scopePath: String) async throws -> [SearchResult] {
        let ctx = contextLines
        return try await Task.detached {
            try GrepRunner.executeGrep(query: query, scopePath: scopePath, contextLines: ctx)
        }.value
    }

    func nextMatch() {
        guard !results.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % results.count
    }

    func previousMatch() {
        guard !results.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + results.count) % results.count
    }

    func copyResult(_ result: SearchResult, contextLines: Int) -> String {
        var parts: [String] = []
        let folderName = URL(fileURLWithPath: result.projectPath).lastPathComponent
        let projectName = ConversationStore.deriveProjectName(from: folderName)
        parts.append("Project: \(projectName)")
        parts.append("Session: \(result.sessionId)")
        parts.append("Type: \(result.messageType)")

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        if result.timestamp != .distantPast {
            parts.append("Time: \(formatter.string(from: result.timestamp))")
        }
        parts.append("")
        if !result.contextBefore.isEmpty { parts.append(result.contextBefore) }
        let plainSnippet = result.snippet
            .replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")
        parts.append(plainSnippet)
        if !result.contextAfter.isEmpty { parts.append(result.contextAfter) }
        return parts.joined(separator: "\n")
    }

    func copyAllResults(contextLines: Int) -> String {
        let separator = "\n" + String(repeating: "=", count: 60) + "\n"
        return results.map { copyResult($0, contextLines: contextLines) }.joined(separator: separator)
    }

    private func resolveScopePath(_ scope: DBSearchScope) -> String {
        let claudeProjects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        switch scope {
        case .allProjects:
            return claudeProjects.path
        case .project(let path):
            return path
        case .session:
            return claudeProjects.path
        }
    }
}

// MARK: - Grep Runner (non-isolated)

private enum GrepRunner {
    static func executeGrep(query: String, scopePath: String, contextLines: Int) throws -> [SearchResult] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = [
            "-r", "-n", "-i",
            "-C", "\(contextLines)",
            "--include=*.jsonl",
            query, scopePath
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return [] }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8), !output.isEmpty else {
            return []
        }

        return parseGrepOutput(output, query: query)
    }

    private static func parseGrepOutput(_ output: String, query: String) -> [SearchResult] {
        let groups = output.components(separatedBy: "\n--\n")
        var results: [SearchResult] = []

        for (index, group) in groups.enumerated() {
            let lines = group.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            var contextBefore: [String] = []
            var contextAfter: [String] = []
            var matchLine = ""
            var matchFilePath = ""
            var foundMatch = false

            for line in lines {
                let parsed = parseGrepLine(line)
                if parsed.isMatch {
                    if foundMatch {
                        contextAfter.append(parsed.content)
                    } else {
                        foundMatch = true
                        matchLine = parsed.content
                        matchFilePath = parsed.filePath
                    }
                } else if foundMatch {
                    contextAfter.append(parsed.content)
                } else {
                    contextBefore.append(parsed.content)
                }
            }

            guard foundMatch else { continue }

            let fileURL = URL(fileURLWithPath: matchFilePath)
            let sessionId = fileURL.deletingPathExtension().lastPathComponent
            let projectPath = extractProjectPath(from: matchFilePath)
            let (messageType, cleanContent, timestamp) = parseJSONLContent(matchLine)
            let snippet = highlightMatch(in: cleanContent, query: query)

            results.append(SearchResult(
                id: index,
                sessionId: sessionId,
                projectPath: projectPath,
                messageUuid: "",
                messageType: messageType,
                timestamp: timestamp,
                snippet: snippet,
                fullText: cleanContent,
                contextBefore: contextBefore.joined(separator: "\n"),
                contextAfter: contextAfter.joined(separator: "\n")
            ))
        }

        return results
    }

    private static func parseGrepLine(_ line: String) -> (filePath: String, lineNumber: Int, content: String, isMatch: Bool) {
        if let range = line.range(of: ".jsonl:", options: .literal) {
            let filePath = String(line[..<line.index(range.upperBound, offsetBy: -1)])
            let rest = String(line[range.upperBound...])
            if let colonIdx = rest.firstIndex(of: ":") {
                let lineNum = Int(rest[..<colonIdx]) ?? 0
                let content = String(rest[rest.index(after: colonIdx)...])
                return (filePath, lineNum, content, true)
            }
        }

        if let range = line.range(of: ".jsonl-", options: .literal) {
            let filePath = String(line[..<line.index(range.upperBound, offsetBy: -1)])
            let rest = String(line[range.upperBound...])
            if let dashIdx = rest.firstIndex(of: "-") {
                let lineNum = Int(rest[..<dashIdx]) ?? 0
                let content = String(rest[rest.index(after: dashIdx)...])
                return (filePath, lineNum, content, false)
            }
        }

        return ("", 0, line, false)
    }

    private static func extractProjectPath(from filePath: String) -> String {
        guard let projectsRange = filePath.range(of: ".claude/projects/") else {
            return URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        }
        let afterProjects = String(filePath[projectsRange.upperBound...])
        let projectFolder = afterProjects.components(separatedBy: "/").first ?? afterProjects
        let projectsDir = String(filePath[..<projectsRange.upperBound])
        return projectsDir + projectFolder
    }

    private static func parseJSONLContent(_ jsonlLine: String) -> (type: String, content: String, timestamp: Date) {
        guard let data = jsonlLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("unknown", jsonlLine, Date.distantPast)
        }

        let type = json["type"] as? String ?? "unknown"
        let timestamp: Date
        if let ts = json["timestamp"] as? String {
            timestamp = JSONLParser.parseTimestamp(ts)
        } else {
            timestamp = Date.distantPast
        }

        var content = ""
        if let message = json["message"] as? [String: Any],
           let messageContent = message["content"] {
            if let text = messageContent as? String {
                content = text
            } else if let blocks = messageContent as? [[String: Any]] {
                let textParts = blocks.compactMap { block -> String? in
                    guard let blockType = block["type"] as? String else { return nil }
                    if blockType == "text", let text = block["text"] as? String { return text }
                    if blockType == "tool_use", let name = block["name"] as? String { return "[Tool: \(name)]" }
                    return nil
                }
                content = textParts.joined(separator: "\n")
            }
        } else if let directContent = json["content"] as? String {
            content = directContent
        }

        if content.isEmpty { content = jsonlLine }
        return (type, content, timestamp)
    }

    private static func highlightMatch(in text: String, query: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: query),
            options: .caseInsensitive
        ) else { return text }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<mark>$0</mark>")
    }
}

# ClaudeCodeCompanion/ClaudeCodeCompanion/Services/SearchEngine.swift

## [P1] Session scope ignored in raw grep

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/SearchEngine.swift:115`
- **Issue:** `resolveScopePath(_:)` ignores the associated session identifier for `.session` scope, returning the generic projects directory instead of the specific session path.
- **Why it matters:** When searching with `useIndex = false` for a specific session, the grep runs over all projects, violating the “bring into view” invariant and returning irrelevant results.
- **Fix direction:** Use the associated `sessionId` (or its file path) to construct the correct directory for the session, e.g., locate the session’s JSONL file within the project and return that path.

# ClaudeCodeCompanion/ClaudeCodeCompanion/Services/DatabaseManager.swift

## [P0] Potential SQLite transaction leak on early error

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/DatabaseManager.swift:127`
- **Issue:** If `execute("BEGIN TRANSACTION")` succeeds but any subsequent statement preparation fails before the `do` block’s `catch`, the transaction remains open because there is no `ROLLBACK` before rethrowing.
- **Why it matters:** Leaving a transaction open can lock the database, causing subsequent operations to fail or deadlock, leading to data loss or app crashes.
- **Fix direction:** Wrap the whole indexing sequence in a `defer` that rolls back the transaction on any error, or move the `BEGIN TRANSACTION` inside the `do` block and ensure a rollback on every early exit.

## [P1] Invariant violation: `search` ORDER BY uses undefined column `rank`

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/DatabaseManager.swift:281`
- **Issue:** The SQL appends `ORDER BY rank` but the SELECT list does not include a `rank` column; FTS5 provides a hidden `rank` function but it must be invoked as `bm25(messages_fts)` or similar.
- **Why it matters:** SQLite will raise “no such column: rank” causing the search to fail at runtime, breaking a core feature.
- **Fix direction:** Replace `ORDER BY rank` with a proper ranking expression, e.g., `ORDER BY bm25(messages_fts)` or compute relevance via `snippet` ordering.

## [P1] Concurrency: `DatabaseManager` methods are not isolated to MainActor but are called from `@MainActor` `ConversationStore`

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/DatabaseManager.swift:4`
- **Issue:** `DatabaseManager` is an `actor` but its public methods are not marked `nonisolated`, so callers on the main actor must `await` them, yet `ConversationStore` calls `try await db.open()` etc. from the main actor without explicit `await` on UI‑thread work, potentially blocking the main thread with heavy I/O.
- **Why it matters:** Performing file I/O (opening DB, creating schema, indexing) on the main actor can block UI, violating responsiveness expectations.
- **Fix direction:** Mark I/O‑heavy methods (e.g., `open`, `createSchema`, `indexMessages`, `search`) as `nonisolated` and dispatch their work to a background queue, or call them from a detached task.

## [P1] Main‑thread blocking: `open()` performs file system creation synchronously

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/DatabaseManager.swift:9‑12`
- **Issue:** `init()` creates the application‑support directory with `FileManager.default.createDirectory` synchronously on the actor’s initializer, which may run on the main thread.
- **Why it matters:** Synchronous file‑system calls on the main thread can cause UI jank, especially on first launch.
- **Fix direction:** Perform directory creation asynchronously (e.g., in `open()` via `Task.detached`) or ensure `DatabaseManager` is instantiated off the main thread.

## [P2] Missing binding for `limit` parameter type safety

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/DatabaseManager.swift:303`
- **Issue:** `sqlite3_bind_int` is used for the `limit` parameter, but SQLite expects an integer literal; binding as `int` is fine, yet the code does not check the return code.
- **Why it matters:** Ignoring the bind result could hide errors if the statement is malformed, leading to silent failures.
- **Fix direction:** Check the return value of `sqlite3_bind_int` and throw a descriptive error on failure.

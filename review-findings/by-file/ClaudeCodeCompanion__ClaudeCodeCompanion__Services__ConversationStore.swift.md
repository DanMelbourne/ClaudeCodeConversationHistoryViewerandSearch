# ClaudeCodeCompanion/ClaudeCodeCompanion/Services/ConversationStore.swift

## [P0] Potential SQLite transaction leak on indexing error

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/DatabaseManager.swift:127`
- **Issue:** If an error is thrown while inserting messages after `BEGIN TRANSACTION`, the transaction is never rolled back.
- **Why it matters:** The database can remain in a transaction state, causing subsequent operations to fail or lock the database, leading to crashes or data loss.
- **Fix direction:** Wrap the insertion loop in a `do { … } catch { try? execute("ROLLBACK"); throw error }` and ensure a `COMMIT` is executed only on success.

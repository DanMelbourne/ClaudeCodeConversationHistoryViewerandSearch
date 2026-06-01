# ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Settings/SourcesManagerView.swift

## [P1] Potential Main‑thread blocking in addSource()

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Settings/SourcesManagerView.swift:131`
- **Issue:** `addSource()` runs `panel.runModal()` and then calls `appViewModel.addSource(name:path:)` directly on the main thread; `addSource` creates a source and immediately starts a background `Task` to re‑index, but the call to `ConversationSource.saveAll` and `loadProjects()` (which may enumerate directories) execute synchronously on the main actor.
- **Why it matters:** Synchronous file‑system checks and directory enumeration can block the UI, especially for large or network‑mounted external sources, leading to jank or apparent hangs.
- **Fix direction:** Move the heavy work (saving, loading projects, and the initial indexing) into a detached background task, returning to the main actor only to update UI state. Use `Task.detached` for `loadProjects()` and ensure `addSource` itself is `@MainActor`‑isolated only for UI state changes.

# Swarm Review Summary

- Provider: `openrouter` / `openai/gpt-oss-120b`
- Prompt: `.swarm-review.md`
- Files reviewed: 19
- Files with findings: 11
- Total findings: **P0=7  P1=16  P2=5**

## `ClaudeCodeCompanion/ClaudeCodeCompanion/ViewModels/AppViewModel.swift`  · P0=3 P1=4 P2=3 · [details](by-file/ClaudeCodeCompanion__ClaudeCodeCompanion__ViewModels__AppViewModel.swift.md)

## [P0] Synchronous file read on main thread in `loadClaudeMD`

- **File:** `ClaudeCodeCompanion/ViewModels/AppViewModel.swift:576`
- **Issue:** `String(contentsOf:globalPath, encoding: .utf8)` is called on the main thread.
- **Why it matters:** Blocking I/O can freeze the UI, especially if the file is large or on a slow volume.
- **Fix direction:** Move the read to a background `Task.detached` and assign `claudeMDGlobalContent` back on `MainActor`.

## [P0] Synchronous file read on main thread in `loadClaudeMD` (project CLAUDE.md)

- **File:** `ClaudeCodeCompanion/ViewModels/AppViewModel.swift:581`
- **Issue:** `String(contentsOf:projectClaudeMD, encoding: .utf8)` is executed on the main thread.
- **Why it matters:** Same UI‑blocking risk as above for potentially large project files.
- **Fix direction:** Perform the read off the main thread and update `claudeMDProjectContent` on `MainActor`.

## [P0] Synchronous file write on main thread in `saveClaudeMD`

- **File:** `ClaudeCodeCompanion/ViewModels/AppViewModel.swift:594` and `598`
- **Issue:** `write(to:atomically:encoding:)` is called on the main thread.
- **Why it matters:** Writing can be slow; performing it on the UI thread may cause jank or hangs.
- **Fix direction:** Dispatch the write to a background task and update `claudeMDHasUnsavedChanges` on `MainActor` after completion.

## [P1] Potential race condition with `loadProjects` cancellation

- **File:** `ClaudeCodeCompanion/ViewModels/AppViewModel.swift:154‑159`
- **Issue:** `loadProjects` launches a detached task that captures `self` weakly, but does not cancel any previous task, so rapid calls could overwrite `projects` with stale data.
- **Why it matters:** UI may display an outdated project list after a quick series of reloads (e.g., adding/removing sources).
- **Fix direction:** Store the `Task` in a property (e.g., `loadProjectsTask`) and cancel it before starting a new one.

## [P1] Invariant violation: `navigateToSearchResult` may set `scrollToMessageId` before view is ready

- **File:** `ClaudeCodeCompanion/ViewModels/AppViewModel.swift:560‑564`
- **Issue:** After loading sessions/messages, `scrollToMessageId` is set after a fixed 300 ms delay, assuming the view has mounted.
- **Why it matters:** If the view takes longer to appear, scrolling will be missed; if it appears sooner, the delay is unnecessary.
- **Fix direction:** Use a view‑level `onAppear` or a `Task` that awaits a `scrollTarget` publisher, removing the arbitrary sleep.

## [P1] Missing cancellation handling for `loadMessagesTask`

- **File:** `ClaudeCodeCompanion/ViewModels/AppViewModel.swift:332‑340`
- **Issue:** The detached task checks `Task.isCancelled` only once after parsing; if cancellation occurs during parsing, the work continues unnecessarily.
- **Why it matters:** Large JSONL files could waste CPU/battery when the user switches sessions quickly.
- **Fix direction:** Periodically check `Task.isCancelled` inside `parseMessagesStreaming` (e.g., after each chunk) and abort early.

## [P1] `searchDebounceTask` created on main actor but not isolated

- **File:** `ClaudeCodeCompanion/ViewModels/AppViewModel.swift:479‑486`
- **Issue:** `Task { @MainActor in … }` creates a task that runs on the main actor, then calls `await performSearch()` which performs heavy DB work on the main thread.
- **Why it matters:** The search operation (`store.db.search`) can be expensive and should run off‑main.
- **Fix direction:** Create a detached task for the debounce delay, then `await MainActor.run` only to update UI after the search completes.

## [P2] `contextLines` is a `Double` but used as an `Int`

- **File:** `ClaudeCodeCompanion/ViewModels/AppViewModel.swift:56` and usage in `createSnippetStatic` (`Int(contextLines)`).
- **Issue:** Storing a line count as a floating‑point value is unnecessary and may cause unexpected truncation.
- **Why it matters:** Minor type‑safety inconsistency; could lead to confusing UI if a non‑integer value is set.
- **Fix direction:** Change `contextLines` to `Int` and adjust bindings accordingly.

## [P2] `searchInSession` does not respect `contextLines` for snippet generation

- **File:** `ClaudeCodeCompanion/ViewModels/AppViewModel.swift:857` and `886`
- **Issue:** Calls `Self.createSnippetStatic(..., contextLines: Int(contextLines))` but `contextLines` is a mutable property; the method uses the global value at call time, not the per‑search context.
- **Why it matters:** Changing `contextLines` after a search starts will not affect the snippet generation, leading to inconsistent UI.
- **Fix direction:** Pass the desired `contextLines` explicitly from the caller or capture it before the background loop.

## [P2] `loadProjects` does not reset `isLoadingProjects` flag

- **File:** `ClaudeCodeCompanion/ViewModels/AppViewModel.swift:132‑160`
- **Issue:** No `isLoadingProjects` property exists, but analogous flag for sessions exists; missing visual feedback when projects are being enumerated.
- **Why it matters:** Users may not see that a reload is in progress, leading to repeated taps.
- **Fix direction:** Introduce an `isLoadingProjects` Bool and set it before/after the background enumeration.

## `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/DatabaseManager.swift`  · P0=1 P1=3 P2=1 · [details](by-file/ClaudeCodeCompanion__ClaudeCodeCompanion__Services__DatabaseManager.swift.md)

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

## `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/FileWatcher.swift`  · P0=1 P1=2 P2=1 · [details](by-file/ClaudeCodeCompanion__ClaudeCodeCompanion__Services__FileWatcher.swift.md)

## [P0] Potential file descriptor leak on start failure  
- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/FileWatcher.swift:24`  
- **Issue:** If `open(path.path, O_EVTONLY)` fails (returns -1), the previously opened descriptor (if any) is not closed before returning.  
- **Why it matters:** Leaking a file descriptor can exhaust the process limit, causing the watcher to stop working and potentially crashing the app.  
- **Fix direction:** Ensure any existing `fileDescriptor` is closed before returning on failure, or restructure `start()` to close the descriptor in a `defer` block after a successful open.  

## [P1] Invariant violation – debounce work item may fire after stop  
- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/FileWatcher.swift:48`  
- **Issue:** `stop()` cancels the current `debounceWorkItem`, but a previously scheduled work item could already be executing on `debounceQueue` when `stop()` returns, leading to `onChange` being called after the watcher is stopped.  
- **Why it matters:** The UI may react to spurious change notifications after the watcher is supposed to be inactive, causing inconsistent state or unnecessary re‑indexing.  
- **Fix direction:** After cancelling, also set `debounceWorkItem = nil` and optionally synchronize with the queue (e.g., `debounceQueue.sync {}`) or use a flag to ignore callbacks after `stop()` has been called.  

## [P1] Concurrency – `onChange` may run off the main thread  
- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/FileWatcher.swift:70`  
- **Issue:** `onChange` is invoked from a background `debounceQueue` without guaranteeing execution on `MainActor`.  
- **Why it matters:** UI updates or model mutations that must occur on the main thread could be performed off‑thread, leading to race conditions or UI glitches.  
- **Fix direction:** Dispatch `onChange` to the main queue (or annotate the closure with `@MainActor`) before calling it.  

## [P2] Missing error handling for `open` permission errors  
- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/FileWatcher.swift:24‑26`  
- **Issue:** The code silently returns when `open` fails, providing no diagnostic information.  
- **Why it matters:** Users receive no feedback if the watcher cannot be started (e.g., due to permission issues), making debugging difficult.  
- **Fix direction:** Log the error (or report via the crash reporter) and optionally surface a non‑intrusive UI indicator.

## `ClaudeCodeCompanion/ClaudeCodeCompanion/Models/ConversationModels.swift`  · P0=1 P1=0 P2=0 · [details](by-file/ClaudeCodeCompanion__ClaudeCodeCompanion__Models__ConversationModels.swift.md)

## [P0] Unstable `ContentBlock.id` using non‑persistent `hashValue`

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Models/ConversationModels.swift:87`
- **Issue:** `ContentBlock.id` builds its identifier from `String.hashValue`, which is randomized per process and not stable across app launches.
- **Why it matters:** SwiftUI relies on stable `id` values for diffing view hierarchies; changing IDs cause view reuse bugs, flickering, or loss of scroll position, leading to a broken user experience.
- **Fix direction:** Replace the hash‑based identifier with a deterministic, stable value (e.g., a UUID, a SHA‑256 hash of the content, or the original string itself).

## `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/ConversationStore.swift`  · P0=1 P1=0 P2=0 · [details](by-file/ClaudeCodeCompanion__ClaudeCodeCompanion__Services__ConversationStore.swift.md)

## [P0] Potential SQLite transaction leak on indexing error

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/DatabaseManager.swift:127`
- **Issue:** If an error is thrown while inserting messages after `BEGIN TRANSACTION`, the transaction is never rolled back.
- **Why it matters:** The database can remain in a transaction state, causing subsequent operations to fail or lock the database, leading to crashes or data loss.
- **Fix direction:** Wrap the insertion loop in a `do { … } catch { try? execute("ROLLBACK"); throw error }` and ensure a `COMMIT` is executed only on success.

## `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/JSONLParser.swift`  · P0=0 P1=2 P2=0 · [details](by-file/ClaudeCodeCompanion__ClaudeCodeCompanion__Services__JSONLParser.swift.md)

## [P1] Incomplete UTF‑8 handling in chunked file reading

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/JSONLParser.swift:34‑40`
- **Issue:** When a chunk ends in the middle of a multi‑byte UTF‑8 sequence, `String(data:chunk,encoding:.utf8)` fails and the code `continue`s, discarding the entire chunk.
- **Why it matters:** Valid characters can be lost, corrupting parsed messages and breaking the “decode‑encode” invariant for conversation content.
- **Fix direction:** Use an incremental UTF‑8 decoder (e.g. `String(decoding:as:)` with a `Data` buffer that preserves leftover bytes) or keep the raw `Data` leftover and prepend it to the next chunk before decoding.

## [P1] Incorrect session ID extraction for sub‑agent files

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/JSONLParser.swift:312‑317`
- **Issue:** `extractSessionId` returns only the file’s base name, so for a sub‑agent file like `UUID/subagents/agent‑123.jsonl` it yields `"agent‑123"` instead of the parent session UUID.
- **Why it matters:** Messages from sub‑agent files are indexed under the wrong session ID, breaking session aggregation and search navigation.
- **Fix direction:** Detect the “subagents” segment and return the top‑level UUID component (the first path component before “/subagents/”). If no sub‑agent segment, fall back to the filename as currently done.

## `ClaudeCodeCompanion/ClaudeCodeCompanion/ClaudeCodeCompanionApp.swift`  · P0=0 P1=1 P2=0 · [details](by-file/ClaudeCodeCompanion__ClaudeCodeCompanion__ClaudeCodeCompanionApp.swift.md)

## [P1] `AppViewModel` instantiated with `@State` instead of `@StateObject`

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/ClaudeCodeCompanionApp.swift:5`
- **Issue:** `AppViewModel` is a reference‑type observable class but is stored in a `@State` property, which recreates the instance on every view refresh.
- **Why it matters:** The view model can be unintentionally re‑initialized, losing all navigation, loading state, and cached data, leading to UI glitches and possible data loss.
- **Fix direction:** Change the property to `@StateObject private var appViewModel = AppViewModel()` so the instance persists for the lifetime of the app.

## `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/SearchEngine.swift`  · P0=0 P1=1 P2=0 · [details](by-file/ClaudeCodeCompanion__ClaudeCodeCompanion__Services__SearchEngine.swift.md)

## [P1] Session scope ignored in raw grep

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/SearchEngine.swift:115`
- **Issue:** `resolveScopePath(_:)` ignores the associated session identifier for `.session` scope, returning the generic projects directory instead of the specific session path.
- **Why it matters:** When searching with `useIndex = false` for a specific session, the grep runs over all projects, violating the “bring into view” invariant and returning irrelevant results.
- **Fix direction:** Use the associated `sessionId` (or its file path) to construct the correct directory for the session, e.g., locate the session’s JSONL file within the project and return that path.

## `ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Search/SearchResultsView.swift`  · P0=0 P1=1 P2=0 · [details](by-file/ClaudeCodeCompanion__ClaudeCodeCompanion__Views__Search__SearchResultsView.swift.md)

## [P1] Incorrect highlight of current search result

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Search/SearchResultsView.swift:137`
- **Issue:** `isCurrentResult` is computed as `result.id == currentIndex`, but `currentIndex` is the array index of the selected result, not the result’s `id`.
- **Why it matters:** The highlighted styling may be applied to the wrong row, confusing users and breaking the “bring into view / highlight current result” invariant.
- **Fix direction:** Compare the result’s position in `appViewModel.searchResults` (or pass the result’s `id`) instead of comparing `result.id` to the index, e.g., `result.id == appViewModel.searchResults[currentIndex].id` or pass the index to the row and compare against the row’s index.

## `ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Settings/SourcesManagerView.swift`  · P0=0 P1=1 P2=0 · [details](by-file/ClaudeCodeCompanion__ClaudeCodeCompanion__Views__Settings__SourcesManagerView.swift.md)

## [P1] Potential Main‑thread blocking in addSource()

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Settings/SourcesManagerView.swift:131`
- **Issue:** `addSource()` runs `panel.runModal()` and then calls `appViewModel.addSource(name:path:)` directly on the main thread; `addSource` creates a source and immediately starts a background `Task` to re‑index, but the call to `ConversationSource.saveAll` and `loadProjects()` (which may enumerate directories) execute synchronously on the main actor.
- **Why it matters:** Synchronous file‑system checks and directory enumeration can block the UI, especially for large or network‑mounted external sources, leading to jank or apparent hangs.
- **Fix direction:** Move the heavy work (saving, loading projects, and the initial indexing) into a detached background task, returning to the main actor only to update UI state. Use `Task.detached` for `loadProjects()` and ensure `addSource` itself is `@MainActor`‑isolated only for UI state changes.

## `ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Sidebar/SidebarView.swift`  · P0=0 P1=1 P2=0 · [details](by-file/ClaudeCodeCompanion__ClaudeCodeCompanion__Views__Sidebar__SidebarView.swift.md)

## [P1] Sidebar view uses `@Bindable var vm = appViewModel` inside body

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Sidebar/SidebarView.swift:7`
- **Issue:** `@Bindable` creates a mutable binding to `appViewModel` but the view also accesses `appViewModel` directly, causing two separate references that can diverge.
- **Why it matters:** UI may not stay in sync with the underlying `AppViewModel` when changes occur, violating the “idempotent” invariant for UI state.
- **Fix direction:** Use either `@EnvironmentObject`/`@ObservedObject` consistently, e.g., replace `@Bindable var vm = appViewModel` with `let vm = appViewModel` and bind directly to `vm` throughout, or remove the extra `@Bindable` and reference `appViewModel` only.

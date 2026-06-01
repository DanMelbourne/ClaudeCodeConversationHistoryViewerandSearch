# ClaudeCodeCompanion/ClaudeCodeCompanion/ViewModels/AppViewModel.swift

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

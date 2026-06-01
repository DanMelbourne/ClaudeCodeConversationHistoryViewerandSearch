# ClaudeCodeCompanion/ClaudeCodeCompanion/Services/FileWatcher.swift

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

# ClaudeCodeCompanion/ClaudeCodeCompanion/ClaudeCodeCompanionApp.swift

## [P1] `AppViewModel` instantiated with `@State` instead of `@StateObject`

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/ClaudeCodeCompanionApp.swift:5`
- **Issue:** `AppViewModel` is a reference‑type observable class but is stored in a `@State` property, which recreates the instance on every view refresh.
- **Why it matters:** The view model can be unintentionally re‑initialized, losing all navigation, loading state, and cached data, leading to UI glitches and possible data loss.
- **Fix direction:** Change the property to `@StateObject private var appViewModel = AppViewModel()` so the instance persists for the lifetime of the app.

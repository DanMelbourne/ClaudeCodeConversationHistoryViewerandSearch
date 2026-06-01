# ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Sidebar/SidebarView.swift

## [P1] Sidebar view uses `@Bindable var vm = appViewModel` inside body

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Sidebar/SidebarView.swift:7`
- **Issue:** `@Bindable` creates a mutable binding to `appViewModel` but the view also accesses `appViewModel` directly, causing two separate references that can diverge.
- **Why it matters:** UI may not stay in sync with the underlying `AppViewModel` when changes occur, violating the “idempotent” invariant for UI state.
- **Fix direction:** Use either `@EnvironmentObject`/`@ObservedObject` consistently, e.g., replace `@Bindable var vm = appViewModel` with `let vm = appViewModel` and bind directly to `vm` throughout, or remove the extra `@Bindable` and reference `appViewModel` only.

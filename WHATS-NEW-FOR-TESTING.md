# What's New for Testing

## Live indexing and Sentry hang hygiene — 2026-07-25

- [x] Automated: filesystem writes in nested project directories notify the recursive watcher; enabled accessible external roots get one watcher, while disabled and duplicate paths do not.
- [x] Automated: the off-main indexing collector finds nested JSONL transcripts and excludes unrelated files.
- [x] Automated: Sentry reporting is suppressed only when XCTest process markers are present.
- [ ] Open the Sources sheet and choose Add Source. Confirm the folder picker appears as a sheet above the app and remains responsive while it is open. Export a project and confirm both save and completion panels are sheets as well.
- [ ] Launch the app, then create or append a JSONL file under `~/.claude/projects/` (including a nested `subagents` folder). After roughly one second, search its unique text without choosing Reindex All; it should appear.
- [ ] Add an enabled external source, append a JSONL transcript beneath it, and confirm it becomes searchable. Disable the source, append again, and confirm the app does not index it until it is re-enabled.

## Cached reconstruction for missing transcripts — 2026-07-25

- [x] Automated: cached reconstruction retains only user and Claude records; it preserves their order, timestamps, text, and raw JSON payload.
- [ ] In the app, open a search result whose original JSONL transcript is missing and choose “View Cached Copy.” Confirm the recovered conversation appears with the “Cached copy — original JSONL unavailable” banner, includes user and Claude messages, and does not include internal queue events.

## Missing search-result transcript — 2026-07-25

- [x] Automated: navigating from a cached search hit whose JSONL session is absent reports “The original conversation file is no longer available on disk.” and leaves the user on search results.
- [ ] In the app, open a search result whose original JSONL transcript has been removed. Confirm the “Conversation Unavailable” alert appears, then dismiss it and verify the search results remain visible rather than two empty columns.

## Build distribution pipeline — 2026-07-21

- [ ] With a Developer ID certificate and a valid `notarytool` profile, run `./dist.sh` and open the generated DMG; drag the app to Applications and launch it.
- [ ] For a local-only package, run `SKIP_NOTARIZE=1 ./dist.sh`; confirm it builds a signed DMG, refreshes `/Applications/Claude Code Companion.app`, and clearly reports that notarization was skipped.

## Build 5 — 2026-07-21

### Sidebar project actions
- [ ] Right-click a project title in the left sidebar and choose “Reveal in Finder” — Finder selects that project’s conversation-history folder.
- [ ] Right-click the empty space within a selected project row as well as its title — the same menu appears across the whole native list-row hit area.
- [ ] With a project selected, choose File → “Reveal Selected Project in Finder” (or press Command-Shift-R) — Finder selects the same folder. Confirm the menu item is disabled when no project is selected.
- [ ] Choose File → “Export Project Conversations” → “Save Consolidated History…” — the same save panel and export behavior as the sidebar menu appears. Confirm it is disabled until a project is selected.
- [ ] Select a project normally after opening its context menu — project/session navigation still works.

### Selected-project export
- [ ] Select a project, open the “Export Project Conversations” menu in the sidebar, and choose “Save Consolidated History…”. The standard save panel opens above the app with a `.txt` filename prefilled.
- [ ] Choose a destination — one text file is created, containing only the selected project's readable conversations from oldest to newest; the most recent interaction is at the end.
- [ ] Confirm that user and Claude messages appear, while system messages and internal queue events do not.
- [ ] After export, confirm the completion sheet reports the number of conversations and chat messages written; choose “Show in Finder” to open the exact exported file.
- [ ] Export over an existing destination and cancel the save panel — the existing file is unchanged.

## Build 4 — 2026-06-20

### Search scope (the reported bug)
- [ ] Select a project (e.g. ScreenshotTray), type a query, switch scope to "Current Project" — results update immediately and show ONLY that project (no other projects like Aluminations)
- [ ] Switch scope back to "All Projects" — results re-run and include all projects
- [ ] "Current Project" includes results from the project's worktrees (merged) too
- [ ] Switching scope with an empty search box does nothing (no error)

### App hangs (Sentry-diagnosed)
- [ ] Search returning many results (300–500) renders without a multi-second beachball
- [ ] Scrolling a large result list is smooth (rows render lazily as you scroll)
- [ ] Clearing/changing a large search doesn't freeze the UI
- [ ] Current search result (up/down navigator) highlights the CORRECT row

## Build 3 — 2026-05-17

### Performance (main focus)
- [ ] Click a large project (1000+ sessions) — loading spinner appears briefly, then sessions populate. No beach ball.
- [ ] Click a session with many messages (500+) — loading spinner appears briefly, conversation renders. No freeze.
- [ ] Rapidly click between different projects — UI stays responsive, no crash
- [ ] Rapidly click between sessions — each loads cleanly, previous load cancelled
- [ ] Overall app startup — sidebar populates without blocking the UI

### Loading indicators
- [ ] Loading spinner shows in sessions column while sessions load
- [ ] Loading spinner shows in conversation column while messages load

## Build 2 — 2026-05-13

### Search Navigation
- [ ] Click a search result — navigates to correct project, session, scrolls to message
- [ ] Search result in subagent file — still navigates and scrolls correctly
- [ ] Message briefly highlights amber when scrolled to

### Worktree Merging
- [ ] Projects with worktrees show as a single entry (e.g. "ScreenshotTray" not 6 entries)
- [ ] Worktree sessions appear when project is selected
- [ ] Session count reflects total across base + worktrees

### External Sources
- [ ] Manage Sources button in sidebar opens sources sheet
- [ ] Add Source → folder picker works (shows hidden files)
- [ ] Added source appears in list with green dot if accessible
- [ ] Toggle eye icon disables/enables source
- [ ] Rename via pencil icon
- [ ] Remove via trash icon
- [ ] Reindex button re-scans the source
- [ ] Disconnected Mac shows gray dot, no error popups
- [ ] Stale source (>24h since index) shows red dot
- [ ] Sources section in sidebar shows compact status

### App Icon
- [ ] Dock icon shows amber gradient with white chat-search element

## Build 1 — 2026-05-13

### Project Browser
- [ ] Projects list populates from `~/.claude/projects/`
- [ ] Project names display correctly (e.g. "ScreenshotTray" not hash strings)
- [ ] Session counts and relative timestamps shown per project
- [ ] Clicking a project loads its sessions in the middle column

### Session List
- [ ] Sessions sorted most-recent-first
- [ ] First user message preview shown (most sessions)
- [ ] Message count badge on each session
- [ ] Clicking a session loads the conversation

### Conversation View
- [ ] User messages show person icon, "You" label, timestamp
- [ ] Claude messages show amber "C" circle, "Claude" label, timestamp
- [ ] Tool use blocks are collapsible (wrench icon)
- [ ] Tool result blocks: short ones inline, long ones collapsed with char count
- [ ] System message toggle works
- [ ] Scrolling through long conversations is smooth

### Search
- [ ] Type a query, press Enter — results appear in detail pane
- [ ] Scope picker: All Projects / Current Project / Current Chat
- [ ] Results grouped by project with count badges
- [ ] Keywords highlighted in amber within results
- [ ] Type badges (USER blue, ASSISTANT amber)
- [ ] Copy button on each result
- [ ] Copy All button in toolbar
- [ ] Context slider adjusts context lines (1-20)
- [ ] Clear search (X button) returns to conversation view

### CLAUDE.md Editor
- [ ] Global tab loads `~/.claude/CLAUDE.md`
- [ ] Project tab with project picker dropdown
- [ ] Auto-save with "Saved" indicator
- [ ] "New from Template" button when project has no CLAUDE.md
- [ ] Character count in status bar

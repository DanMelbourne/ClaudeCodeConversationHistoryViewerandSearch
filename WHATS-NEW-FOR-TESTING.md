# What's New for Testing

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

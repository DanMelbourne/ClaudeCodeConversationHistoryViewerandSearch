# What's New for Testing

## Build 1 — 2026-05-13

### Project Browser
- [ ] Projects list populates from `~/.claude/projects/`
- [ ] Project names display correctly (e.g. "ScreenshotTray" not hash strings)
- [ ] Worktree projects show "(worktree)" suffix
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

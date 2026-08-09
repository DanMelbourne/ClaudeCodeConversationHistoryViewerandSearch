# What's New for Testing

## Project selection loading — 2026-08-09

- [x] Automated: filesystem sessions remain in the list when indexed agent enrichment is empty; indexed sessions are retagged to the selected project and sorted without replacing the filesystem list.
- [x] Automated: the build-script checks require deep signing for nested debug dylibs.
- [x] Verified live: built and launched the installed Debug app, clicked `ScreenshotTray` in the Projects sidebar, and read back the accessibility tree showing the selected project and populated Claude session rows.
- [x] Verified live: after the `ScreenshotTray` click, the selected project remained current and its session list stayed populated while optional agent enrichment ran.

## Version numbering and build stamp — 2026-08-04

- [x] Automated: `BuildInfo` reads the stamped keys, reports "just now / N min / hours / yesterday / N days / on <date>", says "in the future" on clock skew, and reports an unstamped (Xcode-IDE) build as having no build age rather than inventing one.
- [x] Automated: `./scripts/test_build_script.sh` checks every guard in build.sh, dist.sh and verify-build-base.sh.
- [x] Verified: `./build.sh` produced 1.0.7 (7) in /Applications with CCCBuildDate/Branch/Commit/Dirty stamped and a valid signature.
- [ ] Look at the bottom of the sidebar: it should read `v1.0.7 (7) · built <n> min ago`. Hover for the exact time, branch and commit; click to copy them.
- [ ] Run `./build.sh` again and confirm the footer resets to "built just now" after relaunch, and that the build number rises after your next commit.
- [ ] Leave the app open for half an hour and confirm the age text advances without a relaunch.
- [ ] Try `./build.sh` from a branch that is behind `origin/main` and confirm it refuses with a clear reason.


## Incremental byte-offset indexing — 2026-08-04

- [x] Automated: resuming from the recorded offset returns only appended records, for both Claude transcripts and Codex rollouts.
- [x] Automated: a half-written final line is not consumed, and is picked up once completed.
- [x] Automated: an unchanged file costs no re-indexing; multi-byte characters keep offsets on line boundaries.
- [x] Automated: message ids are stable across passes and independent of batch size.
- [ ] With the app running, hold a Claude Code session open and send several messages. Confirm each new message becomes searchable within a couple of seconds and that the same message never appears twice in search results.
- [ ] Run a Codex session in a project, then search for a phrase from its last turn.


## Reveal fix, full-coverage Codex indexing, leaner index — 2026-08-04

- [x] Automated: Reveal prefers an existing working directory, falls back to the transcripts folder, and is nil (menu disabled) when neither exists.
- [x] Automated: streaming a 5,000-message rollout yields every message in bounded batches; the display window keeps head + tail and names the omitted count; small sessions get no notice.
- [x] Automated: `content_raw` is kept only for user/assistant records and capped at 64 KB, while searchable text is untouched.
- [x] Automated: the in-place migration keeps every chat record (including duplicates collapsed to one), blanks raw payloads for non-chat records, caps oversized ones, leaves search working, and is idempotent.
- [ ] First launch after this build migrates the existing index in place. On a multi-gigabyte index this takes several minutes of disk work — confirm the app stays responsive throughout, and that conversations you had cached copies of are still recoverable afterwards.
- [ ] Right-click a project that only has Cursor history and choose Reveal in Finder; confirm its source folder opens. Right-click a project whose folder was deleted; confirm the item is greyed out rather than doing nothing.
- [ ] Open the largest Codex session. Confirm it opens promptly, starts at the first message, ends at the last, and shows the "messages from the middle … are all searchable" notice in between.
- [ ] Search for a phrase you know is in the middle of that session; confirm it is found.


## Codex and Cursor conversation history — 2026-08-04

- [x] Automated: Codex rollouts parse into user/assistant/thinking/tool blocks; `event_msg` records are not duplicated; malformed lines are skipped; thinking stays out of indexed text.
- [x] Automated: an oversized rollout stops at the message cap and ends with a visible truncation notice.
- [x] Automated: Cursor conversations read in header order, tolerate missing bubbles, map type 1/2 to user/assistant, and leave the database byte-identical (read-only).
- [x] Automated: a Codex/Cursor project for the same folder merges into the Claude project row (worktrees included) and session counts add up.
- [x] Automated: agents default to enabled, Claude Code cannot be disabled, and the Codex sessions folder is watched.
- [x] Verified against real data: 541 Codex sessions / 41 projects and 82 Cursor conversations / 4 projects indexed; ScreenshotTray shows claude + codex + cursor in one project row; FTS returns hits from all three agents.
- [ ] Launch the app. In the sidebar, confirm projects you have used from Codex or Cursor show the small agent icons, and that the session list shows Codex/Cursor badges with readable previews.
- [ ] Open a Codex session and a Cursor session. Confirm messages, thinking blocks and tool calls render, and that switching between sessions stays responsive.
- [ ] Search a phrase you know you used in Cursor. Confirm the result carries a Cursor badge and that Open jumps into the conversation at that message.
- [ ] Open Manage Sources. Turn Codex off; confirm its sessions and search hits disappear. Turn it back on; confirm they return after indexing finishes.
- [ ] Export a project that has all three agents. Confirm the text file contains Claude, Codex and Cursor sections with the right assistant names.
- [ ] Known gap: "Reveal in Finder" on a project that exists only in Codex/Cursor points at a `~/.claude/projects` folder that was never created, so nothing opens.


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

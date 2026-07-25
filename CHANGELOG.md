# Changelog

## Build 6 — 2026-07-25

- Keeps the search index current while Claude Code writes conversations, including nested subagent transcripts and enabled external sources.
- Explains when the original conversation transcript was deleted and offers an explicitly labelled cached reconstruction from the local search index.
- Moves transcript discovery and file metadata checks off the main thread, stops synchronous modal loops, and keeps XCTest-only layout work out of Sentry hang reports.

## Build 5 — 2026-07-21

- Added a Developer ID-signed, notarized DMG distribution pipeline.

## Build 5 — 2026-07-21

- Added Finder reveal for each project’s conversation-history folder in the sidebar.
- Added a single-file, plain-text export for the selected project's conversations.
- Exports now omit hidden system and internal records, matching the interactive chat.
- Completed exports report their message count and never replace a destination with an empty file.
- Consolidated project histories now run from the oldest conversation to the newest.

## Build 4 — 2026-06-20

App-hang fixes (diagnosed from Sentry hang reports) and search correctness.

- **HANG FIX**: `SearchResultsView` rewritten from nested `VStack`/`ForEach` sections to a single flat `LazyVStack` over a typed item array. The old structure defeated `LazyVStack` laziness — a search returning 500 results built/tore down all 500 row views eagerly on the main thread, causing multi-second hangs (`swift_arrayDestroy` / deep `NSView` layout recursion in Sentry).
- **SEARCH FIX**: Scope picker now has an `.onChange` that re-runs the search. Previously, switching to "Current Project" left stale "All Projects" results on screen (showing other projects).
- **SEARCH FIX**: "Current Project" scope now matches the project's base folder AND all worktree folders via a single DB base-path query — including worktrees deleted from disk that the old per-`allPaths` query missed.
- Fixed wrong-row highlight in search results (`result.id` was compared against an array index instead of the current result's id).
- Sentry: enabled app-hang tracking (`enableAppHangTracking`, 2s threshold) — the source of these diagnoses.
- In-conversation search (Cmd+F) and Cmd+S save for the CLAUDE.md editor.

## Build 3 — 2026-05-17

Performance overhaul: eliminated all main-thread file I/O that caused UI freezes and spinning beach balls.

- **CRITICAL FIX**: `loadProjects()` filesystem enumeration moved to background thread via `Task.detached`
- **CRITICAL FIX**: `loadSessions()` moved all file reading (first user message, line counting) to background thread
- **CRITICAL FIX**: `loadMessages()` now uses streaming 256KB-chunk FileHandle reading instead of loading entire file into memory as a single String
- **CRITICAL FIX**: `countLines()` replaced with byte-scanning approach — no longer converts entire multi-MB file to String just to count newlines
- Added loading spinners in sessions list and conversation view during background loading
- Task cancellation: rapidly switching projects/sessions cancels in-flight loading tasks
- Cached ISO8601DateFormatter instances (static) instead of creating new ones per parse call
- All parsing methods converted to `nonisolated static` for safe background execution

## Build 2 — 2026-05-13

- Search result click-to-navigate: clicking a search result scrolls to the exact message
- Subagent session resolution: search results in subagent files now navigate correctly
- Worktree merging: project folders with `--claude-worktrees-` suffix merged into parent project
- Custom app icon: amber gradient background with white chat-search element
- External sources: add conversation history from other Macs or custom folders
- Sources manager UI with status indicators (green/red/gray dots), rename, toggle, reindex
- Graceful offline handling for disconnected external sources
- Stale index warning (red dot) when source not indexed in 24+ hours

## Build 1 — 2026-05-13

Initial build of Claude Code Companion.

- Three-column NavigationSplitView: Projects sidebar, Sessions list, Detail pane
- Project discovery from `~/.claude/projects/` with proper name derivation (strips path prefixes, labels worktrees)
- Session list with timestamps, message counts, and first-user-message previews
- Full conversation rendering: user/assistant/system messages with avatars, timestamps, collapsible tool use/result blocks, thinking blocks
- Markdown text rendering (headers, bold, italic, code blocks, inline code, lists, links)
- Full-text search across all projects, current project, or current chat
- Search results grouped by project with keyword highlighting
- Context slider (1-20 lines) in toolbar
- Search navigation (up/down arrows, result counter)
- Copy individual result or all results
- Index mode (parsed content) and Raw mode (JSON view)
- CLAUDE.md editor: Global and per-project tabs, auto-save with 2-second debounce, starter template
- System message toggle
- SQLite FTS5 index backend (DatabaseManager) and raw grep fallback (SearchEngine)
- JSONL streaming parser with 64KB buffer reads
- FileWatcher service for live reindexing

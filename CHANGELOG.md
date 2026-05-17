# Changelog

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

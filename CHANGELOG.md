# Changelog

## Build 10 — 2026-08-04

- Added `build.sh`: derives the build number from the git commit count (always forward, identical for repeat builds of one commit), installs to `/Applications`, stamps the bundle with build date, source branch/commit and an uncommitted-changes flag, re-signs, then verifies the installed version, provenance and that the binary is newer than the sources.
- Added `scripts/verify-build-base.sh`: refuses to build from behind `origin/main` or to move the installed app backwards in history (`CCC_ALLOW_STALE_BASE=1` overrides).
- The sidebar footer now shows `v1.0.7 (7) · built 4 min ago`, refreshing every 30 s, amber past 24 h, with source and exact build time in the tooltip; click copies the details.
- `dist.sh` uses the same version rule and stamps the same provenance keys before signing.
- Added `scripts/test_build_script.sh` guarding the pipeline's disciplines.


## Build 9 — 2026-08-04

- Append-only transcripts resume from a recorded byte offset: a live Claude Code session or Codex rollout now costs only the bytes added since the last pass, instead of a full re-parse and re-index on every append.
- Records with no uuid of their own get a deterministic id from their byte offset, and `messages` gained a unique `(session_id, uuid)` index with `INSERT OR IGNORE`, so a partially-written final line re-read on the next pass can never double-index.
- Measured on this Mac: the in-place migration took 185 s and shrank the index from 6.9 GB to 5.2 GB, collapsing 10,440 duplicate message groups (Claude 806,241 → 799,192; Codex 130,660 → 122,101) with every session and every deleted-transcript recovery row preserved. Search of the migrated index returns 500 hits with context in ~0.18 s.
- Upgrading migrates the existing index in place — trimming payloads and collapsing duplicate rows — instead of rebuilding it, so cached copies of transcripts that have since been deleted from disk survive.
- Duplicate indexing of a session transcript that exists in both a project folder and its worktree copy is collapsed, removing double search hits.


## Build 8 — 2026-08-04

- Reveal in Finder now opens the project's real working directory, so it works for projects that only exist in Codex or Cursor; the menu item disables when nothing is on disk.
- Codex rollouts are streamed and indexed in full — every message of a multi-gigabyte session is searchable. The transcript view keeps the opening and closing 2,000 messages and states how many it left out.
- Index storage policy: `content_raw` is kept only for user and assistant records and capped at 64 KB (it exists solely for the cached-copy view). On this Mac that removes ~1.9 GB of a 6.9 GB index. Searchable text is never trimmed.
- Indexing reads the file ledger once per pass instead of querying per file (~6,000 round trips removed from a no-op refresh).
- Search reuses two prepared statements for context lookups instead of recompiling them per result.
- SQLite tuning: 32 MB page cache, memory temp store, 1 GB mmap, `PRAGMA optimize` on close.
- Changing the storage policy drops and rebuilds the index rather than deleting a million rows through the FTS trigger.


## Build 7 — 2026-08-04

- Indexes Codex CLI/Desktop rollouts from `~/.codex/sessions` and Cursor agent conversations from Cursor's `state.vscdb`, alongside Claude Code transcripts.
- Adapters transcode Codex and Cursor records into the existing Claude-shaped message model, so rendering, FTS search, cached recovery and export work unchanged for all three agents.
- Merges every agent's sessions for the same working directory into one project row, including git worktrees; sessions and search results carry an agent badge.
- Adds per-agent switches in the Sources sheet; disabling an agent purges its rows from the index.
- Adds an `agent` column to `messages` and `indexed_files` with an in-place migration for existing indexes.
- Caps Codex session parsing at 64 MB / 20,000 messages so a multi-gigabyte rollout cannot exhaust memory.


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

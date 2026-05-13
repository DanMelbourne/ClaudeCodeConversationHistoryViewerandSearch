# Changelog

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

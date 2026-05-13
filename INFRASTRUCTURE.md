# Infrastructure

## Dependencies

None. The app uses only macOS system frameworks:
- SwiftUI
- Foundation
- SQLite3 (C API, built into macOS)

## Architecture

| Component | Purpose |
|-----------|---------|
| `AppViewModel` | Main view model — project/session loading, search, CLAUDE.md editing |
| `DatabaseManager` | SQLite FTS5 index for full-text search |
| `JSONLParser` | Streaming JSONL parser with 64KB buffered reads |
| `SearchEngine` | Coordinates FTS5 and raw grep search |
| `ConversationStore` | Bridges DatabaseManager + JSONLParser for indexing |
| `FileWatcher` | FSEvents-based watcher for live reindexing |

## Data Locations

| Path | Purpose |
|------|---------|
| `~/.claude/projects/` | Source conversation transcripts (read-only) |
| `~/Library/Application Support/ClaudeCodeCompanion/index.db` | FTS5 search index (can be deleted safely) |
| `~/.claude/CLAUDE.md` | Global CLAUDE.md (read/write by editor) |
| `<project-dir>/CLAUDE.md` | Per-project CLAUDE.md files (read/write by editor) |

## Configuration

No API tokens or external services. All data is local.

## Build

- Xcode project at `ClaudeCodeCompanion/ClaudeCodeCompanion.xcodeproj`
- Bundle ID: `com.danwarnemail.ClaudeCodeCompanion`
- Minimum deployment: macOS 14.0
- Non-sandboxed (requires access to `~/.claude/projects/`)
- Hardened runtime enabled

## GitHub

Repository: https://github.com/DanMelbourne/ClaudeCodeConversationHistoryViewerandSearch

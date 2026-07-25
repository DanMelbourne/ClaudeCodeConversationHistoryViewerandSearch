# Infrastructure

## Conversation export

Selected-project exports are written as UTF-8 plain-text files through the macOS save panel. They include only the user and assistant records shown by the interactive chat, stream each JSONL file in 256 KB chunks, and atomically replace an existing destination only after a successful write.
The completion sheet reports the exact conversation and message counts, and can reveal the exported file in Finder.

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
| `FileWatcher` | Recursive FSEvents watcher; coalesces source writes before modification-date-aware reindexing |

## Data Locations

| Path | Purpose |
|------|---------|
| `~/.claude/projects/` | Source conversation transcripts (read-only) |
| `~/Library/Application Support/ClaudeCodeCompanion/index.db` | FTS5 search index (can be deleted safely) |
| `~/.claude/CLAUDE.md` | Global CLAUDE.md (read/write by editor) |
| `<project-dir>/CLAUDE.md` | Per-project CLAUDE.md files (read/write by editor) |

## Future history sources

The next adapters should normalize all sources into the existing local SQLite model and label each session with its source. The verified candidates are Codex CLI (`~/.codex/sessions/**/rollout-*.jsonl`), Cursor agent transcripts (`~/.cursor/projects/*/agent-transcripts/*/*.jsonl`), and OpenCode's read-only `opencode.db`. Append-only JSONL needs a persisted byte cursor and archived-source state; a live SQLite source needs a read-only watermark cursor with a stable row-ID tie-break.

## Configuration

No API tokens or external services. All data is local.

## Build

- Xcode project at `ClaudeCodeCompanion/ClaudeCodeCompanion.xcodeproj`
- Bundle ID: `com.danwarnemail.ClaudeCodeCompanion`
- Minimum deployment: macOS 14.0
- Non-sandboxed (requires access to `~/.claude/projects/`)
- Hardened runtime enabled
- `./dist.sh` archives, Developer ID-signs, notarizes, staples, packages `dist/ClaudeCodeCompanion-<version>.dmg`, and refreshes `/Applications/Claude Code Companion.app`. Set `SKIP_INSTALL=1` for packaging-only CI jobs. The identity can be supplied with `SIGNING_IDENTITY`; the notarization keychain profile defaults to `claude-code-companion-notarize`.

## GitHub

Repository: https://github.com/DanMelbourne/ClaudeCodeConversationHistoryViewerandSearch

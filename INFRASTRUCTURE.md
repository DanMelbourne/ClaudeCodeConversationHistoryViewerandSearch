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
| `CodexHistoryProvider` | Parses `~/.codex/sessions/**/rollout-*.jsonl`; caps at 64 MB / 20,000 messages per session |
| `CursorHistoryProvider` | Read-only reader for Cursor's `state.vscdb` (`composerData:` / `bubbleId:` keys) |
| `AgentMessageBuilder` | Transcodes other agents' records into the Claude-shaped record every renderer already reads |
| `AgentKind` / `ProjectPathEncoder` | Agent identity, per-agent switches, and `cwd` → `-Users-dan-Code-Foo` project folder encoding |

Project selection loads filesystem-backed Claude sessions first. Indexed Codex/Cursor sessions are an asynchronous enrichment step and cannot replace the filesystem result when the SQLite lookup is slow or empty.

## Data Locations

| Path | Purpose |
|------|---------|
| `~/.claude/projects/` | Claude Code transcripts (read-only) |
| `~/.codex/sessions/` | Codex rollout transcripts (read-only) |
| `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | Cursor conversations (opened `mode=ro`, never written) |
| `~/Library/Application Support/ClaudeCodeCompanion/index.db` | FTS5 search index (can be deleted safely) |
| `~/.claude/CLAUDE.md` | Global CLAUDE.md (read/write by editor) |
| `<project-dir>/CLAUDE.md` | Per-project CLAUDE.md files (read/write by editor) |

## History sources

| Agent | Source | Incremental cursor |
|-------|--------|--------------------|
| Claude Code | `~/.claude/projects/**/*.jsonl` | file modification date in `indexed_files` |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` | file modification date in `indexed_files` |
| Cursor | `state.vscdb` `composerData:`/`bubbleId:` keys | `lastUpdatedAt` watermark, keyed `cursor://composer/<id>` |

`messages.agent` and `indexed_files.agent` label every row; switching an agent off deletes its rows. Per-agent switches persist in `UserDefaults` under `agentEnabled.<agent>`.

Codex rollouts are streamed in 2,000-message batches with semaphore backpressure, so a gigabyte-scale session is indexed in full without being held in memory; the transcript view separately windows to the first and last 2,000 messages.

## Index storage policy

`DatabaseManager.StoragePolicy` (version 2) governs what is stored per message:

- `content_text` — always stored in full; this is what FTS5 indexes.
- `content_raw` — stored only for `user`/`assistant` records and capped at 64 KB. It exists solely to reconstruct a cached copy when a transcript is deleted, and that view renders chat records only.

Changing `StoragePolicy.version` migrates the existing index **in place** (blank unused raw payloads, truncate oversized ones, collapse duplicate `(session_id, uuid)` rows, VACUUM) and never rebuilds from source — rows for deleted transcripts are unrecoverable and are what the cached-copy view serves. Version is recorded in `index_meta`. The FTS update trigger is `AFTER UPDATE OF content_text`, so the migration does not touch the full-text index.

Incremental indexing: `indexed_files.bytes_indexed` is a byte-offset cursor, so an appended transcript costs only its new bytes. `messages` has a unique `(session_id, uuid)` index and inserts use `INSERT OR IGNORE`, making a re-read of a partially-written final line idempotent. Records with no uuid derive one from `sessionId@byteOffset`.

A full pass parses files in windows of `min(6, cores - 2)` (JSONLParser is `nonisolated` and stateless) and writes through the single DatabaseManager actor.

SQLite settings: WAL, `synchronous=NORMAL`, 32 MB cache, `temp_store=MEMORY`, `mmap_size=1 GB`, `PRAGMA optimize` on close.

Still unadopted: OpenCode's read-only `opencode.db`.

## Configuration

No API tokens or external services. All data is local.

## Build & versioning

| Script | Purpose |
|--------|---------|
| `./build.sh` | Version from commit count → build → install to /Applications → stamp provenance → re-sign → verify. `--debug`, `--clean`, `--no-open`. |
| `./scripts/verify-build-base.sh` | Ancestry guard: not behind `origin/main`, never moves the install backwards. Override: `CCC_ALLOW_STALE_BASE=1`. |
| `./scripts/test_build_script.sh` | Guards the pipeline's disciplines. |
| `./dist.sh` | Signed + notarized DMG, same version rule and stamps. |
| `./scripts/sentry_dsyms.sh` | Best-effort dSYM upload for every normal or distribution build. |

Bundle keys stamped at build time and read by `BuildInfo`: `CCCBuildDate`, `CCCBuildSourceBranch`, `CCCBuildSourceCommit`, `CCCBuildDirty`, `CCCBuildConfiguration`. `CFBundleVersion` = `git rev-list --count HEAD`; `CFBundleShortVersionString` = `MAJOR.MINOR.<count>` (bump MAJOR.MINOR by hand in `Resources/Info.plist`). Both are passed to `xcodebuild` as `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, which override the plist file under `GENERATE_INFOPLIST_FILE`.

Sentry symbols are uploaded to the `trulyuseful/code-companion` project from both `build.sh` and `dist.sh`. The token is read at run time from the login Keychain service `code-companion-sentry`, account `auth-token`; it is never stored in the repository. `SENTRY_INCLUDE_SOURCES=1` is opt-in because symbols alone resolve application frames without sending source files.

## Build

- Xcode project at `ClaudeCodeCompanion/ClaudeCodeCompanion.xcodeproj`
- Bundle ID: `com.danwarnemail.ClaudeCodeCompanion`
- Minimum deployment: macOS 14.0
- Non-sandboxed (requires access to `~/.claude/projects/`)
- Hardened runtime enabled
- `./dist.sh` archives, Developer ID-signs, notarizes, staples, packages `dist/ClaudeCodeCompanion-<version>.dmg`, and refreshes `/Applications/Claude Code Companion.app`. Set `SKIP_INSTALL=1` for packaging-only CI jobs. The identity can be supplied with `SIGNING_IDENTITY`; the notarization keychain profile defaults to `claude-code-companion-notarize`.

## GitHub

Repository: https://github.com/DanMelbourne/ClaudeCodeConversationHistoryViewerandSearch

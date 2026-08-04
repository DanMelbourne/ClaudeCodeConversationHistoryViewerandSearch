# Design Decisions

## 2026-08-04: Build number is the git commit count; the app wears its build stamp
**Decision**: `build.sh` and `dist.sh` set `CFBundleVersion` to `git rev-list --count HEAD` (floored at 1) and `CFBundleShortVersionString` to `MAJOR.MINOR.<count>` from Info.plist, passing both to `xcodebuild` as `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` because `GENERATE_INFOPLIST_FILE` makes the build settings win over the plist file. Each build stamps `CCCBuildDate`, `CCCBuildSourceBranch`, `CCCBuildSourceCommit`, `CCCBuildDirty` and `CCCBuildConfiguration` into the installed bundle, re-signs, and the sidebar footer reads them back.
**Rationale**: Adapted from ScreenshotTray, which learned that a plist-incrementing scheme sticks whenever the bump is never committed. A commit-count version needs no commit of its own, is identical for repeated builds of one commit, and cannot regress. The visible stamp answers the actual question — "is this window the build I just made?" — which a version number alone does not, since the number only changes when the commit does.

## 2026-08-04: The build refuses to go backwards
**Decision**: `scripts/verify-build-base.sh` runs before every build: HEAD must contain `origin/main`, and must contain the commit stamped into the currently installed app. Missing remote or no network downgrades to a warning; `CCC_ALLOW_STALE_BASE=1` is the explicit override. After building, the script verifies the installed version and provenance match this build and that the binary is newer than the newest Swift source, then re-registers with LaunchServices and warns about older copies elsewhere on disk.
**Rationale**: Every one of these guards exists because the failure is silent otherwise: building an old worktree over a newer install, `BUILD SUCCEEDED` with nothing rebuilt, or `open -a` routing to a stale copy LaunchServices registered first.


## 2026-08-04: Parse in parallel, write through one connection
**Decision**: `JSONLParser`'s methods are `nonisolated` (the type holds no mutable state), and a full pass parses files in windows of `min(6, cores - 2)` with `withTaskGroup`, then writes each window's results sequentially through the single `DatabaseManager` actor.
**Rationale**: Parsing is CPU-bound and independent per file; writing must stay single-threaded because SQLite has one writer. Measured on this Mac's history, the win was about 10% (14.4 → 16.2 files/s): indexing is dominated by the FTS5 tokenising insert, not by JSON parsing. Recorded here so the next person does not re-investigate parallel parsing expecting more.


## 2026-08-04: Byte-offset resume for append-only transcripts
**Decision**: `indexed_files.bytes_indexed` records how far each transcript has been read. `JSONLParser.parseFile(at:projectPath:fromByteOffset:)` and `CodexHistoryProvider.stream(at:fromByteOffset:)` resume from there and return the new resume point, which only ever advances past *complete* lines. A file smaller than its recorded offset (rewritten or truncated) is re-read from zero with `replaceExisting: true`.
**Rationale**: Claude Code appends to the live session file continuously and Codex rollouts grow to gigabytes. Modification-date checking already skipped unchanged files, but any *changed* file was re-parsed and re-indexed whole — the dominant cost of a live refresh, and quadratic over a session's lifetime.

## 2026-08-04: Message identity is deterministic, and the index enforces it
**Decision**: Records without their own uuid derive one from `sessionId@byteOffset` (previously a fresh `UUID()` per parse). `messages` carries a unique index on `(session_id, uuid)` and inserts use `INSERT OR IGNORE`.
**Rationale**: A resumed pass legitimately re-reads the last line when it was still mid-write, and random ids made every such re-read a new row. Deterministic ids plus a unique index make re-indexing idempotent by construction rather than by careful bookkeeping.


## 2026-08-04: Index every message, window only the view
**Decision**: `CodexHistoryProvider.stream` reads a rollout in 2,000-message batches with semaphore backpressure, and `ConversationStore` indexes each batch as it arrives (first batch replaces, later batches append). Display uses `parseSession(headLimit:tailLimit:)`, which keeps the first and last 2,000 messages and inserts a system notice naming how many were omitted.
**Rationale**: The earlier 64 MB / 20,000-message cap was applied at parse time, so it silently truncated the *index* too — the tail of a long session was unsearchable, and search results could point at messages the viewer would never show. Splitting the two concerns gives complete search coverage with bounded memory, and no view can usefully render 100,000 messages anyway.

## 2026-08-04: `content_raw` is a cache-recovery payload, not an archive
**Decision**: Store `content_raw` only for user and assistant records, capped at 64 KB (`DatabaseManager.StoragePolicy`). `content_text`, which is what FTS indexes, is never trimmed. The policy carries a version; changing it **migrates the existing index in place** — rewriting oversized and unused payloads, collapsing duplicate `(session_id, uuid)` rows, then VACUUMing — rather than rebuilding from the transcripts.
**Rationale**: Measured on this Mac's 6.9 GB index: `content_raw` was 4.2 GB, of which 804 MB sat on record types the cached-copy view never renders and 1.1 GB was the tail of 5,876 oversized rows (0.6% of messages). Search quality is unaffected because it reads `content_text`.

Migrating in place rather than rebuilding is the important part: rows for transcripts the user has since deleted are the only data in the index that cannot be regenerated, and they are exactly what the cached-copy view exists to serve. A rebuild-from-source reclaimed the same space but silently destroyed them. The FTS update trigger is scoped `AFTER UPDATE OF content_text`, so rewriting `content_raw` costs nothing in the full-text index.

## 2026-08-04: Reveal targets the working directory
**Decision**: `Project.revealTarget` prefers the real `cwd` recorded in the index, falls back to the `~/.claude/projects` transcripts folder, and is nil when neither exists — in which case the menu item is disabled.
**Rationale**: The transcripts folder only exists for projects Claude Code has written to, so Codex/Cursor-only projects previously offered a menu item that silently did nothing. The working directory is what the user actually wants to open, for every agent.


## 2026-08-04: Codex and Cursor adapters transcode into the Claude record shape
**Decision**: `CodexHistoryProvider` and `CursorHistoryProvider` convert their native records into the same JSONL record shape `JSONLParser` already reads (`{"type":…,"uuid":…,"timestamp":…,"agent":…,"message":{"role":…,"content":[blocks]}}`) rather than adding a second renderer, exporter and text-extraction path.
**Rationale**: Rendering, block parsing, FTS text extraction, cached recovery and export are all driven by that one shape. Transcoding at the edge keeps every downstream path single-implementation and means new agents cost one adapter, not a fan-out of format branches.

## 2026-08-04: Agent sessions group by the Claude-encoded working directory
**Decision**: Codex `cwd` and Cursor `trackedGitRepos[].repoPath` are encoded with `ProjectPathEncoder` into the same folder-name form Claude Code uses under `~/.claude/projects` (`/Users/dan/Code/My App` → `-Users-dan-Code-My-App`) and stored as `project_path`. Worktree suffixes fold into the parent project on merge. Cursor conversations with no git repo collect under one clearly-named project.
**Rationale**: A single project row per folder is what the user actually wants — the question is "what happened on this project", not "which tool wrote it". Reusing Claude's encoding makes the merge exact rather than heuristic, and keeps the existing worktree, `ownsPath` and Current-Project search logic working untouched.

## 2026-08-04: Cursor is read through a read-only SQLite connection, with no watcher
**Decision**: Open `state.vscdb` with `mode=ro`, range-scan the `composerData:`/`bubbleId:` key prefixes, and refresh on launch, on demand and when an agent is toggled — no FSEvents watcher. Codex, being append-only JSONL, does get a watcher.
**Rationale**: Cursor's store is a single multi-gigabyte database that every keystroke touches; a watcher on it would fire constantly for changes that are almost never conversation content. Read-only opening guarantees a running Cursor is never disturbed and the file can never be corrupted by Companion.

## 2026-08-04: Bounded parsing for oversized Codex rollouts
**Decision**: `CodexHistoryProvider.parseSession` stops at 64 MB or 20,000 messages and appends a visible system notice; individual tool outputs are truncated at 20,000 characters.
**Rationale**: Real rollouts on this Mac reach 1.5 GB. Reading one whole would exhaust memory and freeze the window, and the tail of a runaway automation log has little review value. A visible notice keeps the truncation honest rather than silent.


## 2026-07-25: Live incremental indexing with recursive source watchers
**Decision**: Keep one recursive filesystem watcher for the local Claude projects root and each enabled, accessible external source. Coalesce events for one second, then run the existing modification-date-aware indexing pass. Restart the watcher set whenever external-source configuration changes.
**Rationale**: Conversation JSONL files are written continuously and can live in nested session folders. A recursive watcher keeps search current without repeatedly reparsing unchanged transcripts, while one shared refresh prevents bursts of filesystem events from starting overlapping scans.

## 2026-07-25: Do not initialise Sentry from XCTest
**Decision**: Detect the XCTest process markers before configuring Sentry and leave reporting disabled there. Keep reportable work off the main actor and present file panels/alerts only as parented sheets, never through a synchronous modal loop.
**Rationale**: App-hang monitoring measures main-thread stalls. XCTest drives the whole SwiftUI application and can intentionally block or lay out large test views, which created debug hang reports with no customer-facing app failure. Sentry also captured an intentional production `NSAlert.runModal` loop; sheets avoid that false-positive path and stay above their parent. Production and normal debug launches retain Sentry reporting.

## 2026-07-25: Multi-harness transcript adapters will share a local, source-labelled index
**Decision**: Keep Companion local-only and introduce source adapters before adding Codex CLI, Cursor, OpenCode, or Copilot histories. Each adapter will normalize source-specific records into the current session/message model, retain source provenance, and use the source's safe incremental cursor: byte offset for append-only JSONL, watermark plus row-ID tie-break for a live SQLite database.
**Rationale**: Rewound demonstrates that Claude Code, Codex CLI, and OpenCode have materially different persistence formats. On this Mac, Cursor has durable agent transcripts at `~/.cursor/projects/*/agent-transcripts/*/*.jsonl` with user/assistant text blocks; its lightweight `~/.cursor/chats` prompt history is not a full conversation source. A source-labelled adapter boundary prevents one parser's assumptions from corrupting another source and preserves a clear recovery path when transcripts disappear.

## 2026-07-25: Recover missing source transcripts from an explicitly labelled SQLite cache
**Decision**: The unavailable-conversation alert offers “View Cached Copy” when a search result's source JSONL cannot be found. The reconstruction uses only indexed user and assistant records, preserves their indexed order and raw payload, and displays a persistent banner stating that it is a cached copy because the original JSONL is missing.
**Rationale**: The local index has enough parsed content to recover useful context, but it is not the canonical source and may omit records that were never indexed. Explicit recovery gives the user access without misrepresenting cache data as an intact transcript.

## 2026-07-25: Explain missing source transcripts during search navigation
**Decision**: When a search result's JSONL transcript is no longer present, keep the user in the search results and show a concise alert that the original conversation is no longer available on disk. Do not silently fall through to an empty session list, and do not display SQLite-indexed text as if it were the original transcript.
**Rationale**: Search data can outlive files because the FTS index is local cache state. Clear provenance matters: indexed snippets are useful for search, but they may omit structure and cannot establish that the original conversation is intact. A future recovery view can explicitly label any SQLite-only content as cached.

## 2026-07-21: Developer ID DMG distribution pipeline
**Decision**: Add a project-root `dist.sh` modelled on ScreenshotTray’s release gates: require a Developer ID identity, archive the Xcode app, re-sign embedded frameworks inside-out with hardened runtime, verify the signature, optionally notarize and staple, then build a compressed DMG containing the app and an Applications alias.
**Rationale**: This app needs the same portable, Gatekeeper-compatible distribution path, but it has no iCloud entitlement, Sparkle framework, helper executable, or custom disk-image assets. Keeping only the applicable stages avoids copying ScreenshotTray-specific release complexity while retaining its security-critical checks.

## 2026-07-21: Finder reveal and consolidated conversation export
**Decision**: Add a native list-selection context menu to the Projects sidebar plus File → “Reveal Selected Project in Finder” (Command-Shift-R), and expose “Export Project Conversations” → “Save Consolidated History…” in both the sidebar actions and File menu. Both export controls are disabled without a selected project and open one shared standard macOS save panel. On success, show the exact exported conversation/message counts and offer Finder reveal; reject a zero-message export.
**Rationale**: A list-level selection context menu owns the full macOS sidebar row hit area, while the File-menu commands remain available when context-menu discovery is unreliable. The project row already owns the filesystem URL for its conversation-history folder, so Finder can reveal the exact data backing that sidebar entry. Exporting follows the interactive chat's default filter—user and assistant records only—then streams that selected project's sessions oldest-to-newest without loading JSONL files into memory; writing first to a sibling temporary file prevents a failed export from damaging an existing destination file.

## 2026-05-13: SQLite FTS5 for search indexing
**Decision**: Use SQLite FTS5 as the primary search engine with raw grep as fallback.
**Alternatives considered**: Apple SearchKit (complex C API), in-memory search (too slow for 1.3GB).
**Rationale**: FTS5 is built into macOS (zero dependencies), supports incremental indexing, and can search millions of rows in milliseconds. Raw grep fallback provides a safety net if the index becomes corrupt.

## 2026-05-13: No external dependencies
**Decision**: Build entirely with macOS built-in frameworks.
**Rationale**: Reduces maintenance burden, avoids Swift package version conflicts, and keeps the app lightweight. SQLite is available via the C API, markdown rendering uses AttributedString, file watching uses DispatchSource.

## 2026-05-13: macOS 14+ minimum
**Decision**: Target macOS 14 (Sonoma) as minimum.
**Rationale**: Enables latest NavigationSplitView APIs, @Observable macro, and AttributedString improvements. Two versions back from current (macOS 16).

## 2026-05-13: Non-sandboxed app
**Decision**: Run without App Sandbox.
**Rationale**: The app needs unrestricted access to ~/.claude/projects/ and ~/.claude/CLAUDE.md. Sandboxing would require complex entitlements and user-granted folder access that would degrade the experience.

## 2026-05-13: Actor-based services
**Decision**: Use Swift actors for DatabaseManager and JSONLParser.
**Rationale**: These perform I/O and must be thread-safe. Actors provide compile-time safety for concurrent access without manual locking.

## 2026-05-13: Claude Code visual aesthetic
**Decision**: Match Claude Code for Mac's dark developer-tool look.
**Rationale**: Target audience is Claude Code developers. Familiar visual language builds trust and feels native to their workflow.

## 2026-06-01: Sentry for crash reporting
**Decision**: Use Sentry (sentry-cocoa via SPM) for crash reporting; first external dependency.
**Alternatives considered**: Apple's built-in crash reporting (limited to App Store apps), custom crash log collection (too much work).
**Rationale**: Sentry is the standard for crash reporting in non-App Store apps. Matches ScreenshotTray's integration pattern for consistency. Privacy-first: no session tracking, no performance tracing, opt-out possible.

## 2026-06-01: Balanced binary reduction for Text concatenation
**Decision**: Use balanced tree reduction instead of left-to-right `Text + Text + ...` chaining for inline markdown rendering.
**Rationale**: SwiftUI's `ConcatenatedTextStorage.resolve()` recurses once per `+` join. Left-to-right chaining of N segments creates O(N) recursion depth, which overflows the 8MB main-thread stack at ~5,500 joins. Balanced reduction keeps depth at O(log N) — 13 levels for 5,500 segments instead of 5,500. Combined with batching plain text runs (instead of one character at a time) and a 50K char guard, this eliminates the crash.

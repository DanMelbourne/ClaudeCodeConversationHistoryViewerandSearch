# Claude Code Companion

## Overview
A native macOS SwiftUI app for browsing, searching, and managing Claude Code conversation history and CLAUDE.md files.

## Tech Stack
- Language: Swift 5+
- Framework: SwiftUI (macOS 14+)
- Database: SQLite FTS5 (via sqlite3 C API, built into macOS)
- Crash reporting: Sentry (via SPM, sentry-cocoa 8.x)
- No other external dependencies

## Project Structure
```
ClaudeCodeCompanion/
  ClaudeCodeCompanion/
    ClaudeCodeCompanionApp.swift    # App entry point
    Models/                         # Data models
    ViewModels/                     # @Observable view models
    Views/                          # SwiftUI views
      Sidebar/                      # Project list sidebar
      ChatList/                     # Session list
      Conversation/                 # Message rendering
      Search/                       # Search results
      Editor/                       # CLAUDE.md editor
      Settings/                     # Sources manager
    Services/                       # Business logic
      JSONLParser.swift             # JSONL file parsing
      DatabaseManager.swift         # SQLite FTS5 index
      ConversationStore.swift       # Data coordinator
      FileWatcher.swift             # FSEvents file watcher
      SearchEngine.swift            # FTS5 + raw grep search
      ClaudeMDManager.swift         # CLAUDE.md file management
      CrashReporter.swift           # Sentry crash reporting wrapper
    Resources/                      # Info.plist, entitlements
```

## Build & Run
```bash
./build.sh
```
Installs to `/Applications/Claude Code Companion.app`, sets the version from the git commit count, and stamps build date + source commit into the bundle (the sidebar footer shows "v1.0.7 (7) · built 4 min ago"). `--debug`, `--clean`, `--no-open` are supported. Never hand-roll an `xcodebuild … SYMROOT=/Applications` install: it leaves an unstamped bundle, so the app cannot tell you which build it is.

For a fast compile/test loop only (no install):
```bash
cd ClaudeCodeCompanion && xcodebuild -scheme ClaudeCodeCompanion -configuration Debug test
```

## Sentry Setup
1. Create a new project at sentry.io for this app
2. Copy the DSN and paste it into `Resources/Info.plist` under the `SentryDSN` key
3. In debug builds, you can override via env var `SENTRY_DSN`
4. CrashReporter.swift is initialised in ClaudeCodeCompanionApp.init()

## Bug Review
```bash
REVIEW_PROVIDER=openrouter python3 scripts/swarm_review.py --all --ext swift --agentic
```
Uses OpenRouter with GPT to review all Swift files. Project-specific bug classes in `.swarm-review.md`.

## Code Style & Conventions
- ViewModels: `@Observable class` (not @MainActor on the class, but methods are @MainActor)
- Services that do I/O: `actor` (e.g., DatabaseManager, JSONLParser)
- Heavy file I/O: `Task.detached` with `nonisolated static` helpers, results assigned back on MainActor
- Use SQLite parameter binding, never string interpolation for queries
- Target macOS 14+ (Sonoma)

## Testing
- Unit tests for JSONLParser, DatabaseManager, ConversationStore
- Test with real JSONL data from ~/.claude/projects/

## Common Patterns
- Three-column NavigationSplitView: Sidebar → ChatList → Detail
- @Environment for passing AppViewModel to views
- FTS5 external content tables synced via triggers
- Debounced file watching and auto-save
- Background loading with Task cancellation for rapid navigation

## Things to Avoid
- Don't load entire JSONL files into memory — stream via FileHandle in 256KB chunks
- Don't block main thread with file I/O — use Task.detached for all filesystem work
- Don't use string interpolation in SQL queries
- Don't hardcode paths — derive from FileManager APIs
- Don't chain SwiftUI Text concatenations deeply (>500 joins) — causes ConcatenatedTextStorage stack overflow. Use balanced binary reduction or AttributedString for long content.

## Testing gaps to watch for
- SwiftUI Text concatenation depth: messages with many inline markdown elements or very long plain text can overflow the stack. Guard with length check and balanced tree reduction.
- Main thread file I/O: any new method that reads files must use Task.detached, never synchronous on MainActor.
- Task cancellation: rapid project/session switching must cancel in-flight loading tasks.
- LazyVStack laziness: a list that can grow to hundreds of items MUST be a single flat LazyVStack (or List) iterating one ForEach. NEVER nest VStack/ForEach per section inside a LazyVStack — the inner content renders eagerly, building every row at once and freezing the main thread (multi-second app hangs, visible in Sentry as `swift_arrayDestroy` / deep `NSView _layoutSubtreeWithOldSize` recursion). Flatten section headers + rows into one typed-item array.
- Picker/control that drives a query: any control that changes search/filter state (scope, sort, filter) must have an `.onChange` that re-runs the query. A Picker bound to state does NOT re-trigger dependent work on its own — stale results stay on screen.
- Current Project search must match the project's base folder AND all worktree folders (`<base>--claude-worktrees-…`), including worktrees deleted from disk. Filter on the DB base path, not the on-disk `allPaths`.
- Agent adapters must transcode into the Claude record shape (`{"type":…,"message":{"role":…,"content":[blocks]}}`) — never add a second renderer/exporter path per agent.
- Any new agent source must set `messages.agent`/`indexed_files.agent` and group by `ProjectPathEncoder.projectPath(for: cwd)`, or its sessions will not merge into the right project.
- Unbounded external transcripts (Codex rollouts reach 1.5 GB) must be parsed with byte/message caps and a visible truncation notice — never read whole into memory.
- Any change to version/provenance handling must keep `CFBundleVersion` monotonic and keep the bundle's `CCCBuild*` stamps in step — an app that cannot say which build it is wastes a test cycle every time. The number is `commit count + BUILD_NUMBER_OFFSET`, floored, computed only by `scripts/build-number.sh`; `build.sh` and `dist.sh` must source it, never re-derive it. The commit count alone is monotonic only while history is append-only — a 2026-08-11 filter-repo pass cut it 60 → 48. After any history rewrite that shortens the log, raise the offset by the number of commits removed and the floor to the highest build ever shipped.
- Never commit build output. `dist/`, `build/`, `DerivedData/`, `.DS_Store` and `.codegraph/` are ignored; the repo went 13.8 MB → 2.2 MB once ~26 MB of xcarchives, dSYMs, signed binaries and a DMG were purged from history.
- Sentry must not initialise under XCTest: test-host layout and deliberate waits are not customer app hangs.
- No regex used per-render may backtrack unboundedly. Inner patterns must be newline-free and length-capped, and text must be scanned in ONE `matches(of:)` pass — never "retry the regexes on the remaining substring" in a loop. Retrying N unbounded regexes per unmatched delimiter is O(delimiters × length): a 16 KB line of `snake_case` prose blocked the main thread for 7.9 s.
- Nothing read inside a SwiftUI row body may be O(n) in the list. `body` runs on every scroll tick, so an O(n) computed property read per row is O(n²) per render pass. Precompute one typed array (row + any derived flags like date dividers) before the `ForEach`.
- Anything derived from message text on every render must be cached or bounded: markdown parsing, snippet building, and layout of raw records. A transcript line can be megabytes (pasted images arrive base64-encoded on one line).
- Size guards on possibly-huge strings must use `utf8.count`, never `count` — `count` walks the string doing grapheme breaking, which is the stall the guard exists to prevent.
- Any per-keystroke work over the loaded conversation must be debounced and run off the main actor.
- Performance claims need a measurement against real data in `~/.claude/projects`, not reasoning. Every fix above was chosen after timing the old and new code on a real transcript.
- `build.sh --debug` must deep-sign the app bundle after stamping so the main executable and its companion `*.debug.dylib` have the same Team ID; otherwise dyld aborts before the window appears.

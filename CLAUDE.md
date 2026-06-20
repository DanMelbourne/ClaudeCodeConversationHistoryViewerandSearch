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
cd ClaudeCodeCompanion
xcodebuild -scheme ClaudeCodeCompanion -configuration Debug build SYMROOT=/Applications
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

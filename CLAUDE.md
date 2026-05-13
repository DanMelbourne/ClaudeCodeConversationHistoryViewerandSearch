# Claude Code Companion

## Overview
A native macOS SwiftUI app for browsing, searching, and managing Claude Code conversation history and CLAUDE.md files.

## Tech Stack
- Language: Swift 5+
- Framework: SwiftUI (macOS 14+)
- Database: SQLite FTS5 (via sqlite3 C API, built into macOS)
- No external dependencies

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
    Services/                       # Business logic
      JSONLParser.swift             # JSONL file parsing
      DatabaseManager.swift         # SQLite FTS5 index
      ConversationStore.swift       # Data coordinator
      FileWatcher.swift             # FSEvents file watcher
      SearchEngine.swift            # FTS5 + raw grep search
      ClaudeMDManager.swift         # CLAUDE.md file management
    Resources/                      # Info.plist, entitlements
```

## Build & Run
```bash
cd ClaudeCodeCompanion
xcodebuild -scheme ClaudeCodeCompanion -configuration Debug build SYMROOT=/Applications
```

## Code Style & Conventions
- ViewModels: `@MainActor @Observable class`
- Services that do I/O: `actor` (e.g., DatabaseManager, JSONLParser)
- Use SQLite parameter binding, never string interpolation for queries
- No external dependencies — everything uses macOS built-in frameworks
- Target macOS 14+ (Sonoma)

## Testing
- Unit tests for JSONLParser, DatabaseManager, ConversationStore
- Test with real JSONL data from ~/.claude/projects/

## Common Patterns
- Three-column NavigationSplitView: Sidebar → ChatList → Detail
- @Environment for passing AppViewModel to views
- FTS5 external content tables synced via triggers
- Debounced file watching and auto-save

## Things to Avoid
- Don't load entire JSONL files into memory — stream line by line
- Don't block main thread with database operations
- Don't use string interpolation in SQL queries
- Don't hardcode paths — derive from FileManager APIs

## Testing gaps to watch for
- (Will be updated as bugs are found)

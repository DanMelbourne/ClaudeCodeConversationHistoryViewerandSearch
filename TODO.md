# TODO

## Current Sprint — v1.0.0

### Done
- [x] Write design spec
- [x] Create GitHub repo
- [x] Scaffold Xcode project structure
- [x] Data models (ConversationModels.swift)
- [x] JSONL parser (JSONLParser.swift)
- [x] SQLite FTS5 database manager (DatabaseManager.swift)
- [x] ConversationStore coordinator
- [x] FileWatcher service
- [x] SearchEngine (FTS5 + raw grep)
- [x] ClaudeMDManager
- [x] AppViewModel
- [x] SwiftUI views (all)
- [x] Build and test initial compilation
- [x] Search result click-to-navigate with scroll-to-message
- [x] Subagent session resolution for search results
- [x] Worktree project merging in sidebar
- [x] Custom app icon (amber gradient + chat-search element)
- [x] External sources management (multi-Mac support)
- [x] Performance audit and fixes (all file I/O off main thread)

### Up Next
- [ ] Add keyboard shortcuts (Cmd+G, Cmd+Shift+G for search navigation)
- [ ] Test CLAUDE.md editor auto-save
- [ ] Add unit tests for JSONLParser and DatabaseManager
- [ ] Build distribution pipeline (build.sh, dist.sh)
- [ ] Set up auto-update via Sparkle

## Future / v1.1
- [ ] Conversation statistics/analytics
- [ ] Export conversations to markdown
- [ ] Semantic search
- [ ] iCloud sync of preferences

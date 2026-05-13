# TODO

## Current Sprint — v1.0.0

### Done
- [x] Write design spec
- [x] Create GitHub repo
- [x] Scaffold Xcode project structure

### In Progress
- [ ] Data models (ConversationModels.swift)
- [ ] JSONL parser (JSONLParser.swift)
- [ ] SQLite FTS5 database manager (DatabaseManager.swift)
- [ ] ConversationStore coordinator
- [ ] FileWatcher service
- [ ] SearchEngine (FTS5 + raw grep)
- [ ] ClaudeMDManager
- [ ] AppViewModel
- [ ] SwiftUI views (all)

### Up Next
- [ ] Build and test initial compilation
- [ ] Fix cross-file reference issues
- [ ] Test with real conversation data
- [ ] Polish conversation rendering
- [ ] Test search across 1.3GB of data
- [ ] Add keyboard shortcuts (Cmd+G, Cmd+Shift+G for search navigation)
- [ ] Add copy functionality for search results
- [ ] Test CLAUDE.md editor auto-save
- [ ] Build to /Applications and verify

## Future / v1.1
- [ ] Conversation statistics/analytics
- [ ] Export conversations to markdown
- [ ] Semantic search
- [ ] iCloud sync of preferences

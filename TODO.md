# TODO

## Current Sprint — v1.0.0

### Done
- [x] `build.sh` with commit-count versioning, provenance stamping and install verification
- [x] In-app build stamp: version + "built N ago" in the sidebar footer
- [x] Reveal in Finder opens the project's real working directory (works for Codex/Cursor-only projects)
- [x] Byte-offset incremental indexing, deterministic message ids, duplicate-proof inserts
- [x] Index storage policy with in-place migration (~1.9 GB reclaimed on this Mac)
- [x] Index Codex (`~/.codex/sessions`) and Cursor (`state.vscdb`) conversation history alongside Claude Code
- [x] Merge all agents' sessions for one working directory into a single project row, with per-session agent badges
- [x] Per-agent switches in Manage Sources; disabling an agent purges its index rows
- [x] Keep the conversation index current with filesystem watchers
- [x] Offer an explicitly labelled cached reconstruction when a searched JSONL transcript is missing
- [x] Explain when a search hit's original JSONL transcript is no longer available on disk
- [x] Add Developer ID signing, notarization, and DMG distribution pipeline
- [x] Reveal a project’s conversation-history folder in Finder from the sidebar
- [x] Export the selected project's conversation-history files into one plain-text file
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
- [x] Fix project selection showing an empty sessions column while indexed agent enrichment is slow
- [ ] Add keyboard shortcuts (Cmd+G, Cmd+Shift+G for search navigation)
- [ ] Test CLAUDE.md editor auto-save
- [ ] Add unit tests for JSONLParser and DatabaseManager
- [ ] Set up auto-update via Sparkle

## Future / v1.1
- [ ] Make transcript indexing source-agnostic, then add Codex CLI and Cursor agent-transcript adapters
- [ ] Store append-only byte cursors and archived-source status so large, deleted transcripts remain searchable without full reparses
- [ ] Add an OpenCode read-only SQLite adapter; investigate the mapped Copilot CLI format after the file-based adapters ship
- [ ] Conversation statistics/analytics
- [ ] Export conversations to markdown
- [ ] Semantic search
- [ ] iCloud sync of preferences

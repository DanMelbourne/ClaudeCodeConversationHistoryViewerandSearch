# Claude Code Companion

A native macOS app for browsing, searching, and managing Claude Code conversation history.

## Features

- **Three-column browser** — Projects, Sessions (with timestamps and previews), and Conversation detail
- **Full-text search** — Search across all projects, current project, or current chat with keyword highlighting
- **Conversation rendering** — Messages displayed with avatars, timestamps, and collapsible tool use/result blocks
- **Search navigation** — Cmd+G / Cmd+Shift+G to step through results; configurable context slider (1-20 lines)
- **Copy results** — One-click copy of individual matches or all results
- **CLAUDE.md editor** — Edit global and per-project CLAUDE.md files with auto-save and starter templates
- **Index and Raw modes** — Toggle between parsed view and raw JSON

## Requirements

- macOS 14 (Sonoma) or later
- Claude Code conversation history at `~/.claude/projects/`

## Building

Open `ClaudeCodeCompanion/ClaudeCodeCompanion.xcodeproj` in Xcode and build (Cmd+B). No external dependencies.

## Data

The app reads JSONL transcript files from `~/.claude/projects/`. It does not modify conversation files. The FTS5 search index is stored at:

```
~/Library/Application Support/ClaudeCodeCompanion/index.db
```

This file can be safely deleted — the app will rebuild it on next launch.

## Uninstalling

1. Delete the app from `/Applications`
2. Optionally remove `~/Library/Application Support/ClaudeCodeCompanion/`

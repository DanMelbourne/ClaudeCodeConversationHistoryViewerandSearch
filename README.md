# Claude Code Companion

A native macOS app for browsing, searching, and managing coding-agent conversation history — Claude Code, Codex and Cursor.

## Features

- **Three-column browser** — Projects, Sessions (with timestamps and previews), and Conversation detail
- **Full-text search** — Search across all projects, current project, or current chat with keyword highlighting
- **Conversation rendering** — Messages displayed with avatars, timestamps, and collapsible tool use/result blocks
- **Search navigation** — Cmd+G / Cmd+Shift+G to step through results; configurable context slider (1-20 lines)
- **Copy results** — One-click copy of individual matches or all results
- **CLAUDE.md editor** — Edit global and per-project CLAUDE.md files with auto-save and starter templates
- **Index and Raw modes** — Toggle between parsed view and raw JSON
- **Finder reveal** — Open a project’s conversation-history folder directly from the sidebar
- **Project export** — Save the selected project's visible user and Claude chat as one plain-text file
- **Live updates** — New and changed Claude Code transcripts, including nested subagent chats and enabled external sources, are indexed automatically
- **Safe recovery** — If a searched transcript was deleted, Companion says so and can show its clearly labelled local cached reconstruction
- **Reveal in Finder** — opens a project's real working directory for any agent
- **Codex and Cursor history** — Codex rollouts and Cursor agent conversations are indexed alongside Claude Code, merged into the same project rows and badged by agent; each agent can be switched off in Manage Sources

## Requirements

- macOS 14 (Sonoma) or later
- Claude Code conversation history at `~/.claude/projects/`
- Optional: Codex history at `~/.codex/sessions/`, Cursor history at `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`

## Building

```bash
./build.sh
```

Installs to `/Applications`, numbers the build from the git commit count, and stamps the source commit and build time into the app — the sidebar footer then shows `v1.0.7 (7) · built 4 min ago` so you always know which build is in front of you. Or open `ClaudeCodeCompanion/ClaudeCodeCompanion.xcodeproj` in Xcode and build (Cmd+B); an IDE build carries no stamp and says so.

For a distributable, notarized DMG and an updated `/Applications/Claude Code Companion.app`, run `./dist.sh`. It requires a Developer ID Application certificate and a `notarytool` keychain profile named `claude-code-companion-notarize` (or set `NOTARY_PROFILE`). Use `SKIP_NOTARIZE=1 ./dist.sh` only for local signed builds.

## Data

The app reads JSONL transcript files from `~/.claude/projects/` and `~/.codex/sessions/`, and reads Cursor's `state.vscdb` with a read-only SQLite connection. It never modifies any of them. The FTS5 search index is stored at:

```
~/Library/Application Support/ClaudeCodeCompanion/index.db
```

This file can be safely deleted — the app will rebuild it on next launch. It is also the local cache used for an explicitly labelled recovery view when Claude Code has deleted an original transcript.

## Uninstalling

1. Delete the app from `/Applications`
2. Optionally remove `~/Library/Application Support/ClaudeCodeCompanion/`

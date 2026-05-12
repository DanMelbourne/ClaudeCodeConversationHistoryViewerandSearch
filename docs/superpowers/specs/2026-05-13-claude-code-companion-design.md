# Claude Code Companion — Design Spec

## Overview

A native macOS app for Claude Code developers that provides:
1. **Conversation History Browser** — browse and search all Claude Code conversation transcripts
2. **CLAUDE.md Editor** — edit global and per-project CLAUDE.md files with templates and a markdown editor

The app recreates the look and feel of Claude Code for Mac — dark theme, monospace typography, developer-tool aesthetic — while following macOS HIG.

## Data Model

### Source Data

Claude Code stores conversation transcripts as JSONL files under `~/.claude/projects/`. Each project directory is named with a mangled path (e.g., `-Users-dan-Code-ScreenshotTray`). Within each:

- `*.jsonl` — conversation session files (UUID-named)
- `*/subagents/*.jsonl` — subagent conversation files
- `CLAUDE.md` — per-project instructions
- `memory/` — memory files

Each JSONL line is a JSON object with a `type` field:
- `user` — user messages (content is string or array of `{type, text}`)
- `assistant` — assistant responses (content is array of `{type: "thinking"|"text"|"tool_use", ...}`)
- `system` — system messages
- `attachment` — file attachments
- `queue-operation` — session lifecycle events
- `last-prompt` — session metadata

Key fields: `timestamp`, `sessionId`, `type`, `message.content`, `cwd`, `gitBranch`, `version`.

### Index Database (SQLite FTS5)

```sql
-- Metadata about indexed files
CREATE TABLE indexed_files (
    path TEXT PRIMARY KEY,
    last_modified REAL,
    session_id TEXT,
    project_path TEXT
);

-- Messages table
CREATE TABLE messages (
    id INTEGER PRIMARY KEY,
    session_id TEXT NOT NULL,
    project_path TEXT NOT NULL,
    uuid TEXT,
    parent_uuid TEXT,
    type TEXT NOT NULL,        -- user, assistant, system, etc.
    timestamp TEXT NOT NULL,
    content_text TEXT,          -- extracted plain text for display
    content_raw TEXT,           -- original JSON for disclosure view
    is_subagent INTEGER DEFAULT 0,
    cwd TEXT,
    git_branch TEXT
);

-- Full-text search index
CREATE VIRTUAL TABLE messages_fts USING fts5(
    content_text,
    content='messages',
    content_rowid='id'
);
```

## Architecture

### Layers

1. **ConversationStore** — singleton managing SQLite database, parsing, indexing
2. **FileWatcher** — FSEvents watcher on `~/.claude/projects/`, triggers incremental reindex
3. **SearchEngine** — FTS5 queries + raw grep fallback
4. **ViewModels** — `ProjectListViewModel`, `ChatListViewModel`, `ConversationViewModel`, `SearchViewModel`, `ClaudeMDEditorViewModel`
5. **Views** — SwiftUI views following three-column NavigationSplitView pattern

### Data Flow

```
~/.claude/projects/   ──FSEvents──>  FileWatcher
                                         │
                                    ConversationStore
                                    (parse JSONL → SQLite FTS5)
                                         │
                              ┌──────────┼──────────┐
                              ▼          ▼          ▼
                        ProjectList  ChatList  ConversationView
                                         │
                                    SearchEngine
                                    (FTS5 or raw grep)
```

## UI Design

### Visual Identity

- **Dark theme** matching Claude Code CLI aesthetic (dark background, light text)
- Supports Light mode too but defaults to system appearance
- **Monospace font** (SF Mono or Menlo) for conversation content
- **SF Pro** for UI chrome (sidebar labels, toolbar)
- **Accent color**: Claude's orange/amber (`#D97706` or similar)
- Vibrancy/translucency on sidebar per HIG
- Follows macOS HIG for toolbar, sidebar, inspector patterns

### Three-Column Layout

```
┌─────────────────────────────────────────────────────────────┐
│ Toolbar: [Search field] [Scope ▾] [Index│Raw] [Context ═══] │
├──────────┬──────────────┬───────────────────────────────────┤
│ Projects │ Chats        │ Conversation / Search Results     │
│          │              │                                   │
│ ScreenshotTray │ May 12 14:30 │ 👤 User:                   │
│ > Curse Words  │ "Fix the bug │ Fix the hover state on...   │
│   Kids Expenses│  in toolbar" │                             │
│   Aluminations │              │ 🤖 Assistant:               │
│                │ May 11 09:15 │ I'll update the hover...    │
│ ──────── │ "Add dark mo │                                   │
│ CLAUDE.md│  de support" │ [▶ Tool Use: Edit file.swift]    │
│ Editor   │              │                                   │
│          │ May 10 16:42 │ 👤 User:                          │
│          │ "Refactor the│ Looks good, ship it              │
│          │  auth module"│                                   │
└──────────┴──────────────┴───────────────────────────────────┘
```

**Column 1 — Projects Sidebar:**
- List of projects with readable names (strip `-Users-dan-Code-` prefix, replace `-` with spaces or derive from actual path)
- Count of sessions per project
- Separator, then "CLAUDE.md Editor" navigation item at bottom
- Sorting: alphabetical, or by most recent chat

**Column 2 — Chat List:**
- Sessions within selected project, sorted most-recent-first
- Each row shows: timestamp (relative, e.g., "2 hours ago"), first user message preview (truncated)
- Badge for message count

**Column 3 — Detail:**
- Conversation viewer (default) or Search results (when searching)
- Conversation viewer renders messages beautifully (see below)
- Search results show matches with surrounding context

### Conversation Rendering

Messages rendered to approximate Claude Desktop's look:

- **User messages**: left-aligned, with "You" label, slightly different background
- **Assistant messages**: left-aligned, with Claude icon/label, markdown rendered:
  - Code blocks with syntax highlighting (use a lightweight highlighter or `AttributedString`)
  - Inline code in monospace with background
  - Lists, bold, italic, headers
  - Tables if feasible
- **Thinking blocks**: collapsed by default, expandable, dimmed/italic style
- **Tool use blocks**: collapsed with tool name and icon visible, expandable to show input/output
- **System messages**: hidden by default, toggle to show
- **Timestamps**: subtle dividers between message groups with time

### Search UI

**Search bar** in toolbar:
- Text field with magnifying glass icon
- **Scope dropdown** immediately to the right: "All Projects" | "Current Project" | "Current Chat"
  - Defaults to scope matching current navigation (viewing a chat → "Current Chat", viewing a project → "Current Project", viewing nothing → "All Projects")
  - User can override
- **Mode toggle**: "Index" | "Raw" (segmented control)
- **Context slider**: labeled "Context" with a slider controlling lines of context shown around each match (range: 1–20 lines, default: 3)

**Search results view** (replaces detail column when searching):
- Results grouped by project → session
- Each result shows: the matched text highlighted in yellow/amber, with N lines of context above and below
- **Navigation**: up/down arrows in toolbar + keyboard shortcuts (⌘G / ⌘⇧G) to jump between matches
- Current match highlighted differently from other matches
- **Copy button** on each result (copies that result's context)
- **"Copy All" button** in toolbar (copies all results with their context)
- Click a result to jump to that point in the full conversation

### CLAUDE.md Editor

Accessed from sidebar (bottom section, always visible):

**Two tabs:**
1. **Global** — edits `~/.claude/CLAUDE.md`
2. **Projects** — dropdown to select a project, edits that project's `CLAUDE.md`

**Editor features:**
- Split view: markdown source (left) + live preview (right), toggleable
- Syntax highlighting for markdown in the source editor
- Standard text editing (undo/redo, find/replace)
- Auto-save with debounce (500ms after last keystroke)
- Dirty indicator in title

**Template system:**
- "New from Template" button when a project has no CLAUDE.md
- Built-in best-practice template covering:
  - Project overview section
  - Tech stack / dependencies
  - Code style and conventions
  - Testing approach
  - Build and run instructions
  - Common patterns in this codebase
  - Things to avoid
- Template is inserted as starter content, user edits from there

## Search Engine

### FTS5 Mode (default)

```swift
func search(query: String, scope: SearchScope, limit: Int) -> [SearchResult] {
    // FTS5 query with snippet() for context
    let sql = """
        SELECT m.id, m.session_id, m.project_path, m.type, m.timestamp,
               snippet(messages_fts, 0, '<mark>', '</mark>', '...', \(contextLines))
        FROM messages_fts
        JOIN messages m ON messages_fts.rowid = m.id
        WHERE messages_fts MATCH ?
        \(scopeClause)
        ORDER BY rank
        LIMIT ?
    """
}
```

### Raw Grep Mode

```swift
func rawGrep(query: String, scope: SearchScope) -> [SearchResult] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
    process.arguments = ["-r", "-n", "-C", "\(contextLines)",
                         "--include=*.jsonl", query, scopePath]
    // Parse grep output into SearchResult objects
}
```

## File Watching & Reindexing

- On app launch: full scan of `~/.claude/projects/`, compare file modification dates against `indexed_files` table, reindex changed/new files
- Continuous: `DispatchSource.makeFileSystemObjectSource` on `~/.claude/projects/` directory
- On file change: parse only the new/changed file, upsert messages into database, update FTS5 index
- Background queue (`DispatchQueue.global(qos: .utility)`) for all indexing work
- Progress indicator in toolbar during reindexing ("Indexing... 42/1299")

## CLAUDE.md Best Practice Template

```markdown
# [Project Name]

## Overview
Brief description of what this project does and its purpose.

## Tech Stack
- Language:
- Framework:
- Key dependencies:

## Project Structure
Describe the directory layout and where key files live.

## Code Style & Conventions
- Naming conventions
- File organization patterns
- Import ordering
- Error handling approach

## Build & Run
How to build, run, and test this project.

## Testing
- Test framework:
- How to run tests:
- Testing conventions:

## Common Patterns
Patterns used throughout this codebase that Claude should follow.

## Things to Avoid
Anti-patterns, deprecated approaches, or specific mistakes to watch for.

## Key Context
Important background information that helps Claude make better decisions.
```

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Search index | SQLite FTS5 | Built into macOS, incremental updates, fast |
| UI framework | SwiftUI | Modern, declarative, native macOS feel |
| Markdown rendering | AttributedString + custom parser | No dependencies, good enough for conversation display |
| Markdown editor | NSTextView wrapped in SwiftUI | Need rich text editing, syntax highlighting |
| File watching | DispatchSource (FSEvents) | Native, low overhead |
| Syntax highlighting (code blocks) | Regex-based lightweight highlighter | No dependencies, covers common languages |

## Minimum OS Version

macOS 14 (Sonoma) — enables latest NavigationSplitView APIs, AttributedString improvements.

## Out of Scope (v1)

- Editing conversations
- Exporting conversations to other formats
- AI-powered search / semantic search
- Conversation statistics/analytics
- iCloud sync

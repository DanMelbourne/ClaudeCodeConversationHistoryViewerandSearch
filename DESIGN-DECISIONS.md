# Design Decisions

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

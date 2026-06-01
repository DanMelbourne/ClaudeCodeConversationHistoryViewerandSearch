# ClaudeCodeCompanion/ClaudeCodeCompanion/Services/JSONLParser.swift

## [P1] Incomplete UTF‑8 handling in chunked file reading

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/JSONLParser.swift:34‑40`
- **Issue:** When a chunk ends in the middle of a multi‑byte UTF‑8 sequence, `String(data:chunk,encoding:.utf8)` fails and the code `continue`s, discarding the entire chunk.
- **Why it matters:** Valid characters can be lost, corrupting parsed messages and breaking the “decode‑encode” invariant for conversation content.
- **Fix direction:** Use an incremental UTF‑8 decoder (e.g. `String(decoding:as:)` with a `Data` buffer that preserves leftover bytes) or keep the raw `Data` leftover and prepend it to the next chunk before decoding.

## [P1] Incorrect session ID extraction for sub‑agent files

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Services/JSONLParser.swift:312‑317`
- **Issue:** `extractSessionId` returns only the file’s base name, so for a sub‑agent file like `UUID/subagents/agent‑123.jsonl` it yields `"agent‑123"` instead of the parent session UUID.
- **Why it matters:** Messages from sub‑agent files are indexed under the wrong session ID, breaking session aggregation and search navigation.
- **Fix direction:** Detect the “subagents” segment and return the top‑level UUID component (the first path component before “/subagents/”). If no sub‑agent segment, fall back to the filename as currently done.

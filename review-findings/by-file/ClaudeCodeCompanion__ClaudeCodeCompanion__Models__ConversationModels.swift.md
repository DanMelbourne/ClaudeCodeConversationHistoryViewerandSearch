# ClaudeCodeCompanion/ClaudeCodeCompanion/Models/ConversationModels.swift

## [P0] Unstable `ContentBlock.id` using non‑persistent `hashValue`

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Models/ConversationModels.swift:87`
- **Issue:** `ContentBlock.id` builds its identifier from `String.hashValue`, which is randomized per process and not stable across app launches.
- **Why it matters:** SwiftUI relies on stable `id` values for diffing view hierarchies; changing IDs cause view reuse bugs, flickering, or loss of scroll position, leading to a broken user experience.
- **Fix direction:** Replace the hash‑based identifier with a deterministic, stable value (e.g., a UUID, a SHA‑256 hash of the content, or the original string itself).

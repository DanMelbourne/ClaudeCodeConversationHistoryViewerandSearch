# ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Search/SearchResultsView.swift

## [P1] Incorrect highlight of current search result

- **File:** `ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Search/SearchResultsView.swift:137`
- **Issue:** `isCurrentResult` is computed as `result.id == currentIndex`, but `currentIndex` is the array index of the selected result, not the result’s `id`.
- **Why it matters:** The highlighted styling may be applied to the wrong row, confusing users and breaking the “bring into view / highlight current result” invariant.
- **Fix direction:** Compare the result’s position in `appViewModel.searchResults` (or pass the result’s `id`) instead of comparing `result.id` to the index, e.g., `result.id == appViewModel.searchResults[currentIndex].id` or pass the index to the row and compare against the row’s index.

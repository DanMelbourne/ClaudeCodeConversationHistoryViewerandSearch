import SwiftUI

struct SearchResultsView: View {
    @Environment(AppViewModel.self) var appViewModel

    var body: some View {
        Group {
            if appViewModel.searchResults.isEmpty {
                noResultsState
            } else {
                resultsList
            }
        }
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("\(appViewModel.searchResults.count) result\(appViewModel.searchResults.count == 1 ? "" : "s") for \"\(appViewModel.searchText)\"")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                    let grouped = groupedResults
                    ForEach(Array(grouped.keys.sorted()), id: \.self) { projectDisplayName in
                        if let projectResults = grouped[projectDisplayName] {
                            ProjectResultSection(
                                projectName: projectDisplayName,
                                results: projectResults,
                                currentIndex: appViewModel.currentSearchResultIndex,
                                searchText: appViewModel.searchText,
                                contextLines: Int(appViewModel.contextLines),
                                onNavigate: { result in
                                    appViewModel.navigateToSearchResult(result)
                                }
                            )
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .onChange(of: appViewModel.currentSearchResultIndex) { _, newIndex in
                guard newIndex < appViewModel.searchResults.count else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(appViewModel.searchResults[newIndex].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Grouped Results (by display name)

    private var groupedResults: [String: [SearchResult]] {
        Dictionary(grouping: appViewModel.searchResults) { $0.projectDisplayName }
    }

    // MARK: - Empty State

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("No results found")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Try a different search term or broaden the scope.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Project Result Section

private struct ProjectResultSection: View {
    let projectName: String
    let results: [SearchResult]
    let currentIndex: Int
    let searchText: String
    let contextLines: Int
    let onNavigate: (SearchResult) -> Void

    private var sessionGroups: [(String, [SearchResult])] {
        let grouped = Dictionary(grouping: results) { $0.sessionId }
        return grouped.sorted { a, b in
            let aDate = a.value.first?.timestamp ?? .distantPast
            let bDate = b.value.first?.timestamp ?? .distantPast
            return aDate > bDate
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(DesignConstants.accentColor)
                Text(projectName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(results.count)")
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DesignConstants.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(DesignConstants.accentColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            ForEach(sessionGroups, id: \.0) { sessionId, sessionResults in
                VStack(alignment: .leading, spacing: 0) {
                    if let firstResult = sessionResults.first {
                        Text(sessionDateLabel(firstResult.timestamp))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    }

                    ForEach(sessionResults) { result in
                        SearchResultRow(
                            result: result,
                            isCurrentResult: result.id == currentIndex,
                            searchText: searchText,
                            contextLines: contextLines,
                            onNavigate: { onNavigate(result) }
                        )
                        .id(result.id)
                    }
                }
            }
        }
    }

    private func sessionDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    let result: SearchResult
    let isCurrentResult: Bool
    let searchText: String
    let contextLines: Int
    let onNavigate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(result.messageType.uppercased())
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(badgeColor)

                Spacer()

                Button {
                    onNavigate()
                } label: {
                    HStack(spacing: 3) {
                        Text("Open")
                            .font(.caption2)
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.caption)
                    }
                    .foregroundStyle(DesignConstants.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Go to this message in conversation")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.fullText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Copy match text")
            }

            highlightedSnippet
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrentResult ? DesignConstants.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isCurrentResult ? DesignConstants.accentColor.opacity(0.4) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Dynamic Snippet with Context

    private var snippetText: String {
        result.dynamicSnippet(query: searchText, contextLines: contextLines)
    }

    private var highlightedSnippet: Text {
        let snippet = snippetText
        var resultText = Text("")

        let parts = snippet.components(separatedBy: "<mark>")
        for (index, part) in parts.enumerated() {
            if index == 0 {
                resultText = resultText + Text(part)
            } else {
                let subparts = part.components(separatedBy: "</mark>")
                if subparts.count >= 2 {
                    resultText = resultText + Text(subparts[0])
                        .bold()
                        .foregroundColor(DesignConstants.accentColor)
                    resultText = resultText + Text(subparts[1...].joined(separator: "</mark>"))
                } else {
                    resultText = resultText + Text(part)
                }
            }
        }

        return resultText
    }

    private var badgeColor: Color {
        switch result.messageType {
        case "user": return .blue
        case "assistant": return DesignConstants.accentColor
        default: return .secondary
        }
    }
}

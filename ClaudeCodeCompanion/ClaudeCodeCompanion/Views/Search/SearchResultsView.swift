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

    // MARK: - Flattened list items
    //
    // The list is flattened into a single array of typed items so the LazyVStack
    // can lazily instantiate ONLY the rows currently on screen. A nested
    // VStack/ForEach structure defeats LazyVStack laziness — every row in a
    // section is built eagerly, which freezes the main thread (and triggers
    // multi-second app hangs) when a search returns hundreds of results.

    private enum ResultListItem: Identifiable {
        case projectHeader(name: String, count: Int)
        case sessionHeader(sessionId: String, date: Date)
        case result(SearchResult)

        var id: String {
            switch self {
            case .projectHeader(let name, _): return "proj-\(name)"
            case .sessionHeader(let sessionId, _): return "sess-\(sessionId)"
            case .result(let r): return "res-\(r.id)"
            }
        }
    }

    private var flatItems: [ResultListItem] {
        let grouped = Dictionary(grouping: appViewModel.searchResults) { $0.projectDisplayName }
        var items: [ResultListItem] = []
        for projectName in grouped.keys.sorted() {
            guard let projectResults = grouped[projectName] else { continue }
            items.append(.projectHeader(name: projectName, count: projectResults.count))

            let sessionGroups = Dictionary(grouping: projectResults) { $0.sessionId }
                .sorted { a, b in
                    (a.value.first?.timestamp ?? .distantPast) > (b.value.first?.timestamp ?? .distantPast)
                }

            for (sessionId, sessionResults) in sessionGroups {
                if let first = sessionResults.first {
                    items.append(.sessionHeader(sessionId: sessionId, date: first.timestamp))
                }
                for result in sessionResults {
                    items.append(.result(result))
                }
            }
        }
        return items
    }

    /// The id of the result currently focused by the up/down navigator.
    private var currentResultId: Int {
        let idx = appViewModel.currentSearchResultIndex
        guard appViewModel.searchResults.indices.contains(idx) else { return -1 }
        return appViewModel.searchResults[idx].id
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

                    ForEach(flatItems) { item in
                        switch item {
                        case .projectHeader(let name, let count):
                            projectHeader(name: name, count: count)
                        case .sessionHeader(_, let date):
                            sessionHeader(date: date)
                        case .result(let result):
                            SearchResultRow(
                                result: result,
                                isCurrentResult: result.id == currentResultId,
                                searchText: appViewModel.searchText,
                                contextLines: Int(appViewModel.contextLines),
                                onNavigate: { appViewModel.navigateToSearchResult(result) }
                            )
                            .id(result.id)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .onChange(of: appViewModel.currentSearchResultIndex) { _, newIndex in
                guard appViewModel.searchResults.indices.contains(newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(appViewModel.searchResults[newIndex].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Section Headers

    private func projectHeader(name: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(DesignConstants.accentColor)
            Text(name)
                .font(.headline)
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DesignConstants.accentColor.opacity(0.15), in: Capsule())
                .foregroundStyle(DesignConstants.accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionHeader(date: Date) -> some View {
        Text(sessionDateLabel(date))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
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
        var segments: [Text] = []

        let parts = snippet.components(separatedBy: "<mark>")
        for (index, part) in parts.enumerated() {
            if index == 0 {
                segments.append(Text(part))
            } else {
                let subparts = part.components(separatedBy: "</mark>")
                if subparts.count >= 2 {
                    segments.append(
                        Text(subparts[0])
                            .bold()
                            .foregroundColor(DesignConstants.accentColor)
                    )
                    segments.append(Text(subparts[1...].joined(separator: "</mark>")))
                } else {
                    segments.append(Text(part))
                }
            }
        }

        // Balanced reduction keeps the Text concatenation tree shallow.
        return Self.balancedReduce(segments)
    }

    private static func balancedReduce(_ texts: [Text]) -> Text {
        guard !texts.isEmpty else { return Text("") }
        if texts.count == 1 { return texts[0] }
        if texts.count == 2 { return texts[0] + texts[1] }
        let mid = texts.count / 2
        return balancedReduce(Array(texts[..<mid])) + balancedReduce(Array(texts[mid...]))
    }

    private var badgeColor: Color {
        switch result.messageType {
        case "user": return .blue
        case "assistant": return DesignConstants.accentColor
        default: return .secondary
        }
    }
}

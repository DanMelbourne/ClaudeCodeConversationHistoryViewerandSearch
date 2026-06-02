import SwiftUI

struct SidebarView: View {
    @Environment(AppViewModel.self) var appViewModel

    var body: some View {
        @Bindable var vm = appViewModel

        List(selection: $vm.selectedProject) {
            Section {
                ForEach(appViewModel.projects) { project in
                    ProjectRow(project: project)
                        .tag(project)
                }
            } header: {
                Text("Projects")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // External sources status
            if !appViewModel.externalSources.isEmpty {
                Section {
                    ForEach(appViewModel.externalSources) { source in
                        SourceStatusRow(source: source)
                    }
                } header: {
                    Text("Sources")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section {
                Button {
                    appViewModel.showSourcesManager = true
                } label: {
                    Label {
                        Text("Manage Sources")
                            .fontWeight(.medium)
                    } icon: {
                        Image(systemName: "externaldrive.badge.plus")
                            .foregroundStyle(DesignConstants.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .help("Add conversation history from other Macs or folders")

                Button {
                    appViewModel.detailDestination = .claudeMDEditor
                    appViewModel.loadClaudeMD()
                } label: {
                    Label {
                        Text("CLAUDE.md Editor")
                            .fontWeight(.medium)
                    } icon: {
                        Image(systemName: "doc.text")
                            .foregroundStyle(DesignConstants.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .help("Edit global or project CLAUDE.md files")
            }
        }
        .listStyle(.sidebar)
        .background(.ultraThinMaterial)
        .sheet(isPresented: Binding(
            get: { appViewModel.showSourcesManager },
            set: { appViewModel.showSourcesManager = $0 }
        )) {
            SourcesManagerView()
                .environment(appViewModel)
        }
        .onChange(of: appViewModel.selectedProject) { _, newProject in
            // Skip when navigateToSearchResult is driving — it manages
            // sessions, selectedSession, and detailDestination itself.
            guard !appViewModel.isNavigatingFromSearch else { return }
            if let project = newProject {
                appViewModel.loadSessions(for: project)
                appViewModel.selectedSession = nil
                appViewModel.detailDestination = .conversation
            }
        }
    }
}

// MARK: - Source Status Row (sidebar compact view)

private struct SourceStatusRow: View {
    let source: ConversationSource

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)

            Text(source.name)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            if let lastIndexed = source.lastIndexed {
                Text(relativeDate(lastIndexed))
                    .font(.caption2)
                    .foregroundColor(source.isStale ? .red : .gray)
            } else {
                Text("never")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .help(statusTooltip)
    }

    private var dotColor: Color {
        if !source.isEnabled { return .gray }
        if !source.isAccessible { return .gray }
        if source.isStale { return .red }
        return .green
    }

    private var statusTooltip: String {
        var parts: [String] = [source.name]
        if !source.isEnabled {
            parts.append("Disabled")
        } else if !source.isAccessible {
            parts.append("Not accessible")
        } else if source.isStale {
            parts.append("Index is stale (>24h)")
        } else {
            parts.append("Up to date")
        }
        parts.append(source.path)
        return parts.joined(separator: "\n")
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Project Row

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(project.displayName)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 8) {
                Label("\(project.sessionCount)", systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let date = project.lastActivityDate {
                    Text(relativeDate(date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
        .help("\(project.sessionCount) session\(project.sessionCount == 1 ? "" : "s")")
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

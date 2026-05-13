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

            Section {
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
        .onChange(of: appViewModel.selectedProject) { _, newProject in
            if let project = newProject {
                appViewModel.loadSessions(for: project)
                appViewModel.selectedSession = nil
                appViewModel.detailDestination = .conversation
            }
        }
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

import SwiftUI

struct SourcesManagerView: View {
    @Environment(AppViewModel.self) var appViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingName: String = ""
    @State private var editingSourceId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            agentsSection
            Divider()
            sourcesList
            Divider()
            footer
        }
        .frame(width: 520, height: 470)
    }

    // MARK: - Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coding Agents")
                .font(.caption)
                .foregroundStyle(.tertiary)

            ForEach(AgentKind.allCases) { agent in
                AgentToggleRow(
                    agent: agent,
                    isOn: appViewModel.enabledAgents.contains(agent),
                    isBusy: appViewModel.isIndexing,
                    onChange: { appViewModel.setAgent(agent, enabled: $0) }
                )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Conversation Sources")
                    .font(.headline)
                Text("Add Claude Code history from other Macs or folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding()
    }

    // MARK: - Sources List
    // (Agent toggles live above; sources below are extra Claude Code folders.)

    private var sourcesList: some View {
        Group {
            if appViewModel.externalSources.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(appViewModel.externalSources) { source in
                        SourceRow(
                            source: source,
                            isEditingName: editingSourceId == source.id,
                            editingName: editingSourceId == source.id ? $editingName : .constant(""),
                            onToggle: { appViewModel.toggleSource(source.id) },
                            onStartRename: {
                                editingName = source.name
                                editingSourceId = source.id
                            },
                            onFinishRename: {
                                appViewModel.renameSource(source.id, to: editingName)
                                editingSourceId = nil
                            },
                            onCancelRename: { editingSourceId = nil },
                            onRemove: { appViewModel.removeSource(source.id) },
                            onReindex: { Task { await appViewModel.reindexSource(source) } }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("No external sources")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Add a folder containing Claude Code conversations\nfrom another Mac or location.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                addSource()
            } label: {
                Label("Add Source", systemImage: "plus")
            }
            .help("Browse for a folder containing .claude/projects")

            Spacer()

            if !appViewModel.externalSources.isEmpty {
                Button("Reindex All") {
                    Task { await appViewModel.reindexAllSources() }
                }
                .help("Re-scan all accessible sources")
                .disabled(appViewModel.isIndexing)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func addSource() {
        let panel = NSOpenPanel()
        panel.title = "Select Claude Code Projects Folder"
        panel.message = "Choose a .claude/projects folder or any folder containing .jsonl conversation files"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let name = suggestName(for: url)
            appViewModel.addSource(name: name, path: url.path)
        }
    }

    private func suggestName(for url: URL) -> String {
        let path = url.path
        // If it's a /Volumes/ path, use the volume name
        if path.hasPrefix("/Volumes/") {
            let components = path.components(separatedBy: "/")
            if components.count >= 3 {
                return components[2]
            }
        }
        // Otherwise use the parent folder name
        return url.deletingLastPathComponent().lastPathComponent
    }
}

// MARK: - Agent Toggle Row

private struct AgentToggleRow: View {
    let agent: AgentKind
    let isOn: Bool
    let isBusy: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.symbolName)
                .frame(width: 18)
                .foregroundStyle(isInstalled ? DesignConstants.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName)
                    .font(.subheadline)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(get: { isOn }, set: onChange))
                .labelsHidden()
                .disabled(agent == .claude || isBusy || !isInstalled)
                .help(toggleHelp)
        }
    }

    private var isInstalled: Bool {
        switch agent {
        case .cursor:
            return CursorHistoryProvider.isAvailable()
        default:
            return FileManager.default.fileExists(atPath: agent.defaultHistoryLocation.path)
        }
    }

    private var statusText: String {
        guard isInstalled else { return "No history found on this Mac" }
        return agent.defaultHistoryLocation.path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private var toggleHelp: String {
        if agent == .claude { return "Always included" }
        if !isInstalled { return "Not installed" }
        return isOn ? "Stop indexing" : "Index this agent"
    }
}

// MARK: - Source Row

private struct SourceRow: View {
    let source: ConversationSource
    let isEditingName: Bool
    @Binding var editingName: String
    let onToggle: () -> Void
    let onStartRename: () -> Void
    let onFinishRename: () -> Void
    let onCancelRename: () -> Void
    let onRemove: () -> Void
    let onReindex: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            nameAndPath
            Spacer()
            actions
        }
        .padding(.vertical, 4)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .help(statusTooltip)
    }

    private var dotColor: Color {
        if !source.isEnabled {
            return .gray
        }
        if !source.isAccessible {
            return .gray
        }
        if source.isStale {
            return .red
        }
        return .green
    }

    private var statusTooltip: String {
        if !source.isEnabled { return "Disabled" }
        if !source.isAccessible { return "Not accessible — is the Mac connected?" }
        if source.isStale { return "Last indexed more than 24 hours ago" }
        return "Up to date"
    }

    private var nameAndPath: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isEditingName {
                TextField("Name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .onSubmit { onFinishRename() }
                    .onExitCommand { onCancelRename() }
            } else {
                Text(source.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Text(source.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let lastIndexed = source.lastIndexed {
                Text("Last indexed \(relativeDate(lastIndexed))")
                    .font(.caption2)
                    .foregroundStyle(source.isStale ? .red : .secondary)
            } else {
                Text("Never indexed")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button { onStartRename() } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Rename")

            Button { onToggle() } label: {
                Image(systemName: source.isEnabled ? "eye" : "eye.slash")
                    .font(.caption)
                    .foregroundStyle(source.isEnabled ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help(source.isEnabled ? "Disable" : "Enable")

            Button { onReindex() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Reindex now")
            .disabled(!source.isAccessible)

            Button { onRemove() } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.borderless)
            .help("Remove source")
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

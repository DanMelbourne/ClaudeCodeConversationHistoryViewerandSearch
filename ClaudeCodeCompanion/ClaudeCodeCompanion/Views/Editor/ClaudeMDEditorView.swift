import SwiftUI

struct ClaudeMDEditorView: View {
    @Environment(AppViewModel.self) var appViewModel
    @State private var saveTimer: Timer?
    @State private var showSavedIndicator = false

    var body: some View {
        @Bindable var vm = appViewModel

        VStack(spacing: 0) {
            // Tab bar
            tabBar

            Divider()

            // Editor area
            editorContent

            Divider()

            // Status bar
            statusBar
        }
        .onAppear {
            appViewModel.loadClaudeMD()
        }
        .onDisappear {
            saveTimer?.invalidate()
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        @Bindable var vm = appViewModel

        return HStack(spacing: 0) {
            ForEach(AppViewModel.ClaudeMDTab.allCases, id: \.self) { tab in
                Button {
                    appViewModel.claudeMDEditorTab = tab
                    appViewModel.loadClaudeMD()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab == .global ? "globe" : "folder")
                            .font(.caption)
                        Text(tab.rawValue)
                            .font(.subheadline)
                            .fontWeight(appViewModel.claudeMDEditorTab == tab ? .semibold : .regular)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        appViewModel.claudeMDEditorTab == tab
                            ? DesignConstants.accentColor.opacity(0.12)
                            : Color.clear
                    )
                    .foregroundStyle(
                        appViewModel.claudeMDEditorTab == tab
                            ? DesignConstants.accentColor
                            : .secondary
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Project picker (when on Project tab)
            if appViewModel.claudeMDEditorTab == .project {
                Picker("Project", selection: $vm.claudeMDEditorProject) {
                    Text("Select Project").tag(nil as Project?)
                    ForEach(appViewModel.projects) { project in
                        Text(project.displayName).tag(project as Project?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                .onChange(of: appViewModel.claudeMDEditorProject) { _, _ in
                    appViewModel.loadClaudeMD()
                }
                .padding(.trailing, 8)
            }

            // New from Template button (when project has no CLAUDE.md)
            if appViewModel.claudeMDEditorTab == .project &&
               appViewModel.claudeMDEditorProject != nil &&
               appViewModel.claudeMDProjectContent.isEmpty {
                Button {
                    appViewModel.claudeMDProjectContent = claudeMDTemplate
                    appViewModel.claudeMDHasUnsavedChanges = true
                    scheduleAutoSave()
                } label: {
                    Label("New from Template", systemImage: "doc.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Create CLAUDE.md from a starter template")
                .padding(.trailing, 12)
            }
        }
        .padding(.horizontal, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Editor Content

    private var editorContent: some View {
        @Bindable var vm = appViewModel

        return Group {
            switch appViewModel.claudeMDEditorTab {
            case .global:
                MonospaceTextEditor(
                    text: $vm.claudeMDGlobalContent,
                    onChange: {
                        appViewModel.claudeMDHasUnsavedChanges = true
                        scheduleAutoSave()
                    }
                )
            case .project:
                if appViewModel.claudeMDEditorProject != nil {
                    MonospaceTextEditor(
                        text: $vm.claudeMDProjectContent,
                        onChange: {
                            appViewModel.claudeMDHasUnsavedChanges = true
                            scheduleAutoSave()
                        }
                    )
                } else {
                    selectProjectPrompt
                }
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            // File path
            if appViewModel.claudeMDEditorTab == .global {
                Text("~/.claude/CLAUDE.md")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else if let project = appViewModel.claudeMDEditorProject {
                Text("\(project.displayName)/CLAUDE.md")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Save indicator
            if showSavedIndicator {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if appViewModel.claudeMDHasUnsavedChanges {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DesignConstants.accentColor)
                        .frame(width: 6, height: 6)
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Character count
            let charCount = currentContent.count
            Text("\(charCount) characters")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Select Project Prompt

    private var selectProjectPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("Select a project")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Choose a project from the dropdown above to edit its CLAUDE.md file.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Current Content

    private var currentContent: String {
        switch appViewModel.claudeMDEditorTab {
        case .global: return appViewModel.claudeMDGlobalContent
        case .project: return appViewModel.claudeMDProjectContent
        }
    }

    // MARK: - Auto-save

    private func scheduleAutoSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            Task { @MainActor in
                appViewModel.saveClaudeMD()
                showSavedIndicator = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showSavedIndicator = false }
                }
            }
        }
    }

    // MARK: - Template

    private var claudeMDTemplate: String {
        """
        # Project Instructions

        ## Overview
        Brief description of this project.

        ## Architecture
        Key architectural decisions and patterns.

        ## Code Style
        - Follow existing patterns in the codebase
        - Use descriptive variable and function names

        ## Testing
        - Write tests for all new functionality
        - Run tests before committing

        ## Important Notes
        - Add project-specific instructions here
        """
    }
}

// MARK: - Monospace Text Editor

private struct MonospaceTextEditor: View {
    @Binding var text: String
    let onChange: () -> Void

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .padding(4)
            .onChange(of: text) { _, _ in
                onChange()
            }
    }
}

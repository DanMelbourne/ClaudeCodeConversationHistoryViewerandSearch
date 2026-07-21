import AppKit
import SwiftUI

@main
struct ClaudeCodeCompanionApp: App {
    @State private var appViewModel = AppViewModel()

    init() {
        CrashReporter.configure(enabled: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appViewModel)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reveal Selected Project in Finder") {
                    guard let project = appViewModel.selectedProject else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([project.path])
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(appViewModel.selectedProject == nil)

                Menu("Export Project Conversations") {
                    Button("Save Consolidated History…") {
                        appViewModel.presentSelectedProjectExportSavePanel()
                    }
                }
                .disabled(appViewModel.selectedProject == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    if appViewModel.detailDestination == .claudeMDEditor {
                        appViewModel.saveClaudeMD()
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Conversation") {
                    if appViewModel.detailDestination == .conversation && appViewModel.selectedSession != nil {
                        appViewModel.showConversationSearch.toggle()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

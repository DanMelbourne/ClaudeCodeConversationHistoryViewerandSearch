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
    }
}

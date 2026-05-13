import SwiftUI

@main
struct ClaudeCodeCompanionApp: App {
    @State private var appViewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appViewModel)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
    }
}

import SwiftUI

struct DetailView: View {
    @Environment(AppViewModel.self) var appViewModel

    var body: some View {
        Group {
            switch appViewModel.detailDestination {
            case .conversation:
                ConversationView()

            case .searchResults:
                SearchResultsView()

            case .claudeMDEditor:
                ClaudeMDEditorView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

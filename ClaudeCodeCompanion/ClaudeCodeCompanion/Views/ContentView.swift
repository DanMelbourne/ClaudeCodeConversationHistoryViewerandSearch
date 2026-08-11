import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) var appViewModel

    var body: some View {
        @Bindable var vm = appViewModel

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            ChatListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
        } detail: {
            DetailView()
        }
        .alert(
            "Conversation Unavailable",
            isPresented: Binding(
                get: { appViewModel.navigationErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        appViewModel.navigationErrorMessage = nil
                    }
                }
            )
        ) {
            if appViewModel.unavailableSearchResult != nil {
                Button("View Cached Copy") {
                    appViewModel.viewCachedConversation()
                }
            }
            Button("OK", role: .cancel) {
                appViewModel.navigationErrorMessage = nil
            }
        } message: {
            Text(appViewModel.navigationErrorMessage ?? "")
        }
        .toolbar(id: "mainToolbar") {
            // Search field
            ToolbarItem(id: "search", placement: .automatic) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search conversations...", text: $vm.searchText)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 180, maxWidth: 260)
                        .onSubmit {
                            Task { @MainActor in
                                await appViewModel.immediateSearch()
                            }
                        }
                        .onChange(of: appViewModel.searchText) { _, _ in
                            appViewModel.debouncedSearch()
                        }
                    if !appViewModel.searchText.isEmpty {
                        Button {
                            appViewModel.searchText = ""
                            appViewModel.searchResults = []
                            appViewModel.detailDestination = .conversation
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            // Scope picker
            ToolbarItem(id: "scope", placement: .automatic) {
                Picker("Scope", selection: $vm.searchScope) {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .help("Search scope")
                .onChange(of: appViewModel.searchScope) { _, _ in
                    // Re-run the search so the new scope takes effect immediately.
                    guard !appViewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    Task { @MainActor in
                        await appViewModel.immediateSearch()
                    }
                }
            }

            // Mode toggle
            ToolbarItem(id: "mode", placement: .automatic) {
                Picker("Mode", selection: $vm.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                .help("Index mode shows parsed content; Raw mode shows JSON")
            }

            // Context slider
            ToolbarItem(id: "context", placement: .automatic) {
                HStack(spacing: 4) {
                    Text("Context:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $vm.contextLines, in: 1...20, step: 1)
                        .frame(width: 80)
                    Text("\(Int(appViewModel.contextLines))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                }
                .help("Number of context lines around search results")
            }

            // Search navigation
            ToolbarItem(id: "searchNav", placement: .automatic) {
                HStack(spacing: 2) {
                    Button {
                        appViewModel.navigateSearchResult(direction: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(!appViewModel.isSearchActive)
                    .help("Previous result")

                    Button {
                        appViewModel.navigateSearchResult(direction: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(!appViewModel.isSearchActive)
                    .help("Next result")

                    if appViewModel.isSearchActive {
                        Text("\(appViewModel.currentSearchResultIndex + 1)/\(appViewModel.searchResults.count)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40)
                    }
                }
            }

            // Copy All
            ToolbarItem(id: "copyAll", placement: .automatic) {
                Button {
                    appViewModel.copyAllSearchResults()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(!appViewModel.isSearchActive)
                .help("Copy all search results")
            }

            // Indexing progress
            ToolbarItem(id: "indexing", placement: .automatic) {
                if appViewModel.isIndexing {
                    HStack(spacing: 6) {
                        ProgressView(value: appViewModel.indexingProgress)
                            .frame(width: 60)
                        Text(appViewModel.indexingStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            await appViewModel.initialize()
        }
    }
}

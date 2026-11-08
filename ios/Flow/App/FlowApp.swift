import SwiftUI
import FlowCore

@main
struct FlowApp: App {
    @State private var state = AppState()
    var body: some Scene {
        WindowGroup { RootView().environment(state).tint(FlowTheme.accent) }
    }
}

@MainActor @Observable
final class AppState {
    let feed = FeedStore()
    let library: LibraryStore
    let downloads: DownloadStore
    var query = FeedQuery()
    var token = ""
    var message: String?

    init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Flow", directoryHint: .isDirectory)
        library = LibraryStore(fileURL: directory.appending(path: "bookmarks.json"))
        downloads = DownloadStore(directory: URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory))
        do { token = try TokenStore.read() ?? "" }
        catch { message = error.localizedDescription }
    }

    func toggleBookmark(_ post: MediaPost) -> String? {
        do { try library.toggle(post); return nil }
        catch { return error.localizedDescription }
    }

    func saveToken(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try TokenStore.save(trimmed)
        token = trimmed
    }
}

enum FlowTheme {
    static let accent = Color(red: 0.96, green: 0.23, blue: 0.32)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}

private enum AppTab: Hashable { case discover, flow, library, downloads, settings }

struct RootView: View {
    @Environment(AppState.self) private var state
    @State private var tab: AppTab = .discover

    var body: some View {
        TabView(selection: $tab) {
            DiscoverView()
                .tabItem { Label("发现", systemImage: "square.grid.2x2") }.tag(AppTab.discover)
            ImmersiveScreen(isActive: tab == .flow)
                .tabItem { Label("沉浸", systemImage: "play.rectangle") }.tag(AppTab.flow)
            LibraryView()
                .tabItem { Label("收藏", systemImage: "bookmark") }.tag(AppTab.library)
            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }.tag(AppTab.downloads)
            SettingsView()
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(AppTab.settings)
        }
        .preferredColorScheme(tab == .flow ? .dark : nil)
        .task(id: state.query) { await state.feed.refresh(query: state.query, token: state.token) }
        .alert("提示", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) {
            Button("知道了", role: .cancel) { state.message = nil }
        } message: { Text(state.message ?? "") }
    }
}

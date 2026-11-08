import SwiftUI
import UIKit
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
    let immersiveFeed = FeedStore()
    let library: LibraryStore
    let downloads: DownloadStore
    var query = FeedQuery()
    var immersiveMedia: MediaFilter = MediaFilter(rawValue: UserDefaults.standard.string(forKey: "immersiveMedia") ?? "") ?? .all {
        didSet { UserDefaults.standard.set(immersiveMedia.rawValue, forKey: "immersiveMedia") }
    }
    var ratings: Int = (UserDefaults.standard.object(forKey: "contentRatings") as? Int ?? 1) & ContentRating.allMask {
        didSet {
            UserDefaults.standard.set(ratings, forKey: "contentRatings")
            query.ratings = ratings
        }
    }
    var immersiveQuery: FeedQuery {
        var value = query
        value.media = immersiveMedia
        value.username = ""
        return value
    }
    private(set) var token = ""
    private(set) var credentialRevision = 0
    var message: String?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncRunID: UUID?
    @ObservationIgnored private var syncAgain = false

    init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Flow", directoryHint: .isDirectory)
        library = LibraryStore(fileURL: directory.appending(path: "bookmarks.json"))
        downloads = DownloadStore(directory: URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory))
        query.ratings = ratings
        do { token = try TokenStore.read() ?? "" }
        catch { message = error.localizedDescription }
    }

    func saveToken(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let unchanged = token == trimmed
        try TokenStore.save(trimmed)
        if !unchanged {
            syncTask?.cancel()
            syncTask = nil; syncRunID = nil; syncAgain = false
        }
        token = trimmed
        credentialRevision += 1
        if trimmed.isEmpty { library.disconnect() }
    }

    func syncLibrary() async {
        guard !token.isEmpty else { return }
        if let syncTask {
            syncAgain = true
            await syncTask.value
            return
        }
        let key = token, runID = UUID()
        let task = Task { @MainActor in
            repeat {
                syncAgain = false
                await library.sync(token: key)
            } while syncAgain && !Task.isCancelled && token == key
        }
        syncTask = task; syncRunID = runID
        await task.value
        if syncRunID == runID { syncTask = nil; syncRunID = nil }
    }

    func allows(_ post: MediaPost) -> Bool { post.isAllowed(ratings: ratings) }
}

struct FeedTaskID: Hashable {
    let query: FeedQuery
    var revision = 0
    var enabled = true
}

enum FlowTheme {
    static let accent = Color("AccentColor")
    static let background = adaptive(0xF7F5F1, 0x141516)
    static let surface = adaptive(0xFFFDFA, 0x1F2022)
    static let inset = adaptive(0xF0EDE7, 0x292A2C)
    static let ink = adaptive(0x292724, 0xF3EFE9)
    static let muted = adaptive(0x716D68, 0xAAA6A0)
    static let line = adaptive(0xE4DFD8, 0x36383B)
    static let accentSoft = adaptive(0xF3E4DF, 0x3E2B27)
    static let onAccent = adaptive(0xFFFFFF, 0x292724)
    static let pageInset: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 14
    static let overlay = Color.black.opacity(0.48)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

private enum AppTab: Hashable { case discover, flow, library, downloads, settings }

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .discover

    var body: some View {
        TabView(selection: $tab) {
            DiscoverView(isActive: tab == .discover)
                .tabItem { Label("发现", systemImage: "square.grid.2x2") }.tag(AppTab.discover)
            ImmersiveScreen(isActive: tab == .flow)
                .tabItem { Label("沉浸", systemImage: "play.rectangle") }.tag(AppTab.flow)
            LibraryView(isActive: tab == .library)
                .tabItem { Label("收藏", systemImage: "bookmark") }.tag(AppTab.library)
            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }.tag(AppTab.downloads)
            SettingsView()
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(AppTab.settings)
        }
        .toolbarBackground(FlowTheme.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .preferredColorScheme(tab == .flow ? .dark : nil)
        .task(id: FeedTaskID(query: state.query, revision: state.credentialRevision)) { await state.feed.refresh(query: state.query, token: state.token) }
        .task(id: FeedTaskID(query: state.immersiveQuery, revision: state.credentialRevision)) { await state.immersiveFeed.refresh(query: state.immersiveQuery, token: state.token) }
        .task(id: state.credentialRevision) { await state.syncLibrary() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await state.syncLibrary() } }
        }
        .onChange(of: tab) { _, value in
            if value == .library { Task { await state.syncLibrary() } }
        }
        .alert("提示", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) {
            Button("知道了", role: .cancel) { state.message = nil }
        } message: { Text(state.message ?? "") }
    }
}

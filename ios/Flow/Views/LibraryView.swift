import SwiftUI
import FlowCore

struct LibraryView: View {
    var isActive = true
    @Environment(AppState.self) private var state
    @State private var selection: MediaPost?
    @State private var folderID: String?
    @State private var search = ""
    @State private var addingFolder = false
    @State private var folderName = ""
    @State private var webFolder: BookmarkCollection?

    private var posts: [MediaPost] {
        state.library.posts(in: folderID).filter {
            state.allows($0) && (search.isEmpty || $0.creator.localizedCaseInsensitiveContains(search)
                || $0.title.localizedCaseInsensitiveContains(search) || ($0.prompt?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(state.library.posts(in: folderID).count) 个收藏")
                                .font(.system(.title2, weight: .semibold)).foregroundStyle(FlowTheme.ink)
                            Spacer()
                            if state.library.isSyncing { ProgressView() }
                        }
                        if let account = state.library.account, !state.token.isEmpty {
                            Text("@\(account.username) · \(state.library.pendingCount > 0 ? "有待同步的修改" : "Civitai 收藏夹")").font(.caption).foregroundStyle(.secondary)
                        } else { Text("保存在这台设备 · 设置 API Key 后自动同步").font(.caption).foregroundStyle(.secondary) }
                        if let error = state.library.syncError {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("重试同步") { Task { await state.syncLibrary() } }.font(.caption)
                        }
                    }.padding(.horizontal, FlowTheme.pageInset)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            folderButton("全部收藏", id: nil)
                            ForEach(state.library.availableCollections) { folder in
                                Button {
                                    if folder.supportsMedia { folderID = folder.id }
                                    else { webFolder = folder }
                                } label: {
                                    Label(folder.name + (folder.isLocalRecovery ? " · 仅本机" : ""), systemImage: folder.supportsMedia ? "folder" : "globe")
                                }.buttonStyle(FlowChipStyle(selected: folderID == folder.id))
                                    .accessibilityAddTraits(folderID == folder.id ? .isSelected : [])
                                    .contextMenu {
                                        if folder.webURL != nil { Button("在 Civitai 查看", systemImage: "globe") { webFolder = folder } }
                                        if folder.isLocalRecovery {
                                            Button("重新同步到网站", systemImage: "arrow.triangle.2.circlepath") {
                                                do { try state.library.resumeSync(collectionID: folder.id); Task { await state.syncLibrary() } }
                                                catch { state.message = error.localizedDescription }
                                            }.disabled(state.token.isEmpty)
                                        }
                                    }
                            }
                        }.padding(.horizontal, FlowTheme.pageInset)
                    }.scrollIndicators(.hidden)
                    if let error = state.library.errorMessage {
                        MessageState(title: "收藏暂时不可用", message: error, symbol: "externaldrive.badge.exclamationmark")
                    } else if posts.isEmpty {
                        MessageState(title: "还没有匹配的收藏", message: "在作品上轻点书签，可多选收藏夹；也可以调整内容等级或搜索词。", symbol: "bookmark")
                    } else { PostGrid(posts: posts, select: { selection = $0 }, isActive: isActive && selection == nil && webFolder == nil) }
                }.padding(.vertical, 16)
            }
            .background(FlowTheme.background)
            .navigationTitle("收藏").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { folderName = ""; addingFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .accessibilityLabel("新建收藏夹")
                }
            }
            .searchable(text: $search, prompt: "搜索我的收藏")
            .refreshable { await state.syncLibrary() }
            .fullScreenCover(item: $selection) { DetailScreen(initialPost: $0, source: .library, libraryPosts: posts) }
            .onChange(of: state.library.availableCollections.map(\.id)) { _, ids in
                if let folderID, !ids.contains(folderID) { self.folderID = nil }
            }
            .sheet(item: $webFolder) { folder in
                if let url = folder.webURL { NavigationStack { CivitaiWebView(url: url).navigationTitle(folder.name).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { webFolder = nil } } } } }
            }
            .alert("新建收藏夹", isPresented: $addingFolder) {
                TextField("名称（最多 30 字）", text: $folderName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    do { folderID = try state.library.createCollection(name: folderName); Task { await state.syncLibrary() } }
                    catch { state.message = error.localizedDescription }
                }
            }
        }
    }

    private func folderButton(_ title: String, id: String?) -> some View {
        Button { folderID = id } label: {
            Text(title)
        }.buttonStyle(FlowChipStyle(selected: folderID == id))
            .accessibilityAddTraits(folderID == id ? .isSelected : [])
    }
}

struct BookmarkSheet: View {
    let post: MediaPost
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var name = ""
    @State private var error: String?
    @State private var baseline = Set<String>()
    @State private var initialized = false
    @State private var initialAccountID: Int?
    @State private var accountChanged = false
    private let defaultDraftID = "default-draft"

    var body: some View {
        NavigationStack {
            Form {
                Section("保存到收藏夹 · 可多选") {
                    if selected.contains(defaultDraftID) || state.library.availableCollections.filter(\.supportsMedia).isEmpty {
                        Button {
                            if !selected.insert(defaultDraftID).inserted { selected.remove(defaultDraftID) }
                        } label: {
                            HStack {
                                Label("默认收藏", systemImage: "folder")
                                Spacer()
                                Image(systemName: selected.contains(defaultDraftID) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                    ForEach(state.library.availableCollections.filter(\.supportsMedia)) { folder in
                        Button {
                            if !selected.insert(folder.id).inserted { selected.remove(folder.id) }
                        } label: {
                            HStack {
                                Label(folder.name + (folder.isLocalRecovery ? " · 仅本机" : ""), systemImage: "folder")
                                Spacer()
                                Image(systemName: selected.contains(folder.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(folder.id) ? FlowTheme.accent : .secondary)
                            }.foregroundStyle(.primary)
                        }.accessibilityAddTraits(selected.contains(folder.id) ? .isSelected : [])
                    }
                }
                Section("新建收藏夹") {
                    TextField("收藏夹名称", text: $name)
                    Button("创建并选中") {
                        do {
                            selected.insert(try state.library.createCollection(name: name)); selected.remove(defaultDraftID); name = ""
                            Task { await state.syncLibrary() }
                        }
                        catch { self.error = error.localizedDescription }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if state.library.contains(post) {
                    Section {
                        Button("从所有收藏夹移除", role: .destructive) { selected = []; save(removingAll: true) }.disabled(accountChanged)
                    }
                }
            }
            .flowListSurface()
            .navigationTitle("收藏作品").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(accountChanged) }
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true; initialAccountID = state.library.account?.id
                selected = state.library.collectionIDs(for: post)
                baseline = selected
                if state.library.availableCollections.filter(\.supportsMedia).isEmpty {
                    selected.insert(defaultDraftID)
                } else if selected.isEmpty, let first = state.library.availableCollections.first(where: \.supportsMedia) { selected.insert(first.id) }
            }
            .onChange(of: state.library.account?.id) { _, id in
                if let initialAccountID, initialAccountID != id {
                    accountChanged = true; error = "同步账户已切换，请关闭面板后重新选择收藏夹。"
                } else { initialAccountID = id }
            }
        }.presentationDetents([.medium, .large])
    }
    private func save(removingAll: Bool = false) {
        do {
            var destination = selected
            if destination.remove(defaultDraftID) != nil { destination.insert(try state.library.createCollection(name: "默认收藏")) }
            try state.library.save(post, to: destination, replacing: removingAll ? nil : baseline)
            Task { await state.syncLibrary() }; dismiss()
        }
        catch { self.error = error.localizedDescription }
    }
}

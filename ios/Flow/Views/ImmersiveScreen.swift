import SwiftUI
import FlowCore

struct ImmersiveScreen: View {
    let isActive: Bool
    @Environment(AppState.self) private var state
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if state.feed.isLoading { ProgressView().tint(.white).frame(maxHeight: .infinity) }
            else if state.feed.posts.isEmpty {
                MessageState(title: "还没有可浏览的作品", message: state.feed.errorMessage ?? "在发现页调整筛选，或重新加载。", symbol: "play.rectangle") {
                    Task {
                        if state.feed.hasMore { await state.feed.loadMore(token: state.token) }
                        else { await state.feed.refresh(query: state.query, token: state.token) }
                    }
                }.frame(maxHeight: .infinity)
            } else {
                FeedPager(posts: state.feed.posts, initialID: state.feed.posts.first?.id, isActive: isActive, loadsMore: true)
            }
            HStack(spacing: 10) {
                Text("FLOW").font(.system(.headline, design: .rounded, weight: .black)).tracking(3)
                Text("\(state.query.sort.title) · 上滑发现更多").font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer()
            }.padding(20).allowsHitTesting(false)
        }
        .toolbarBackground(.black, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

enum DetailSource { case discover, library }

struct DetailScreen: View {
    let initialPost: MediaPost
    let source: DetailSource
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var savedSnapshot: [MediaPost] = []

    private var posts: [MediaPost] {
        let current = source == .library ? savedSnapshot : state.feed.posts
        return current.contains(where: { $0.id == initialPost.id }) ? current : [initialPost] + current
    }

    var body: some View {
        FeedPager(posts: posts, initialID: initialPost.id, isActive: true, loadsMore: source == .discover)
            .background(.black)
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                        .background(.black.opacity(0.4), in: Circle())
                }.padding(16).accessibilityLabel("关闭全屏")
            }
            .preferredColorScheme(.dark)
            .onAppear { if source == .library { savedSnapshot = state.library.posts.filter(\.isSafeForWork) } }
    }
}

struct FeedPager: View {
    let posts: [MediaPost]
    let initialID: Int?
    let isActive: Bool
    let loadsMore: Bool
    @Environment(AppState.self) private var state
    @State private var focusedID: Int?

    init(posts: [MediaPost], initialID: Int?, isActive: Bool, loadsMore: Bool) {
        self.posts = posts
        self.initialID = initialID
        self.isActive = isActive
        self.loadsMore = loadsMore
        _focusedID = State(initialValue: initialID)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(posts) { post in
                    MediaPage(post: post, isActive: isActive && focusedID == post.id)
                        .containerRelativeFrame(.vertical)
                        .id(post.id)
                }
            }.scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $focusedID)
        .background(.black)
        .task(id: focusedID) {
            if loadsMore, let post = posts.first(where: { $0.id == focusedID }) {
                await state.feed.loadMoreIfNeeded(after: post, token: state.token)
            }
        }
        .overlay(alignment: .topTrailing) {
            if loadsMore, focusedID == posts.last?.id, state.feed.hasMore,
               !state.feed.isLoadingMore, state.feed.errorMessage == nil {
                Button("继续加载") { Task { await state.feed.loadMore(token: state.token) } }
                    .font(.caption.weight(.semibold)).padding(10)
                    .background(.black.opacity(0.5), in: Capsule()).padding(.top, 18).padding(.trailing, 18)
            }
        }
        .overlay(alignment: .top) {
            if loadsMore && state.feed.isLoadingMore { ProgressView().padding(.top, 65) }
            if loadsMore, let error = state.feed.errorMessage, !state.feed.isLoading {
                Button { Task { await state.feed.loadMore(token: state.token) } } label: {
                    Text("\(error) 点此重试").font(.caption).padding(12).background(.ultraThinMaterial, in: Capsule())
                }.padding(.top, 62).padding(.horizontal, 16)
            }
        }
    }
}

private struct MediaPage: View {
    let post: MediaPost
    let isActive: Bool
    @Environment(AppState.self) private var state
    @State private var promptPresented = false
    @State private var isSaving = false
    @State private var result: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if post.isVideo {
                    VideoSurface(url: post.url, poster: post.previewURL, isActive: isActive && !promptPresented)
                } else {
                    RemoteImage(url: post.url, fit: true)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack {
                    Spacer()
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(post.isVideo ? "MOTION / VIDEO" : "STILL / IMAGE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.white.opacity(0.6))
                            Text("@\(post.creator)").font(.title3.weight(.bold))
                            Text(post.prompt ?? post.title).font(.subheadline).lineLimit(3).foregroundStyle(.white.opacity(0.8))
                            Button { promptPresented = true } label: {
                                Label("查看生成信息", systemImage: "text.viewfinder").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(.white.opacity(0.16), in: Capsule())
                            }.padding(.top, 4)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(spacing: 20) {
                            Button { result = state.toggleBookmark(post) } label: {
                                actionIcon(state.library.contains(post) ? "bookmark.fill" : "bookmark", label: "收藏")
                                    .foregroundStyle(state.library.contains(post) ? FlowTheme.accent : .white)
                            }.accessibilityLabel(state.library.contains(post) ? "取消收藏" : "收藏作品")
                            Link(destination: post.webURL) {
                                actionIcon("bubble.right", label: "评论")
                            }.accessibilityLabel("在 Civitai 查看评论")
                            ShareLink(item: post.webURL) { actionIcon("square.and.arrow.up", label: "分享") }
                            Menu {
                                Button("保存到相册", systemImage: "photo.badge.arrow.down") {
                                    isSaving = true
                                    Task {
                                        defer { isSaving = false }
                                        do { try await PhotoSaver.save(post); result = "已保存到系统相册。" }
                                        catch { result = error.localizedDescription }
                                    }
                                }
                                Button("下载到文件（含生成信息）", systemImage: "folder") {
                                    do {
                                        try state.downloads.enqueue(DownloadPlan.media(post), token: state.token)
                                        result = "已加入下载，可在“下载”页查看进度和导出文件。"
                                    } catch { result = error.localizedDescription }
                                }
                            } label: {
                                if isSaving { ProgressView().frame(width: 44, height: 48) }
                                else { actionIcon("arrow.down.to.line", label: "下载") }
                            }.disabled(isSaving).accessibilityLabel("下载图片或视频")
                        }
                    }.padding(.horizontal, 22).padding(.bottom, 28)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $promptPresented) { PromptSheet(post: post) }
        .alert("提示", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("知道了", role: .cancel) { result = nil }
        } message: { Text(result ?? "") }
    }

    private func actionIcon(_ symbol: String, label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 25, weight: .regular)).frame(width: 44, height: 30)
            Text(label).font(.system(size: 10, weight: .medium))
        }.frame(minWidth: 44, minHeight: 44)
    }
}

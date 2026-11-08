import SwiftUI
import FlowCore

struct ImmersiveScreen: View {
    let isActive: Bool
    @Environment(AppState.self) private var state
    var body: some View {
        @Bindable var state = state
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if state.immersiveFeed.isLoading { ProgressView().tint(.white).frame(maxHeight: .infinity) }
            else if state.immersiveFeed.posts.isEmpty {
                MessageState(title: "还没有可浏览的作品", message: state.immersiveFeed.errorMessage ?? "在发现页调整筛选，或重新加载。", symbol: "play.rectangle") {
                    Task {
                        if state.immersiveFeed.hasMore { await state.immersiveFeed.loadMore(token: state.token) }
                        else { await state.immersiveFeed.refresh(query: state.immersiveQuery, token: state.token) }
                    }
                }.frame(maxHeight: .infinity)
            } else {
                FeedPager(posts: state.immersiveFeed.posts, initialID: state.immersiveFeed.posts.first?.id, isActive: isActive, loadsMore: true, usesImmersiveFeed: true)
            }
            HStack(spacing: 10) {
                FlowBrand(onDark: true)
                Text(state.query.sort.title).font(.caption).foregroundStyle(.white.opacity(0.65))
                Spacer()
                MediaModeMenu(selection: $state.immersiveMedia)
            }.padding(.horizontal, FlowTheme.pageInset).padding(.vertical, 12)
        }
        .toolbarBackground(.black, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

enum DetailSource { case discover, library }

struct DetailScreen: View {
    let initialPost: MediaPost
    let source: DetailSource
    var libraryPosts: [MediaPost]? = nil
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var savedSnapshot: [MediaPost] = []
    @State private var mediaFilter: MediaFilter = .all
    @State private var modeIsSelected = false
    @State private var modeFeed = FeedStore()
    @State private var initialized = false
    private var modeQuery: FeedQuery { var query = state.query; query.media = mediaFilter; return query }

    private var posts: [MediaPost] {
        if source == .discover && modeIsSelected { return modeFeed.posts.filter(state.allows) }
        let current = source == .library ? savedSnapshot : state.feed.posts
        let available = current.contains(where: { $0.id == initialPost.id }) ? current : [initialPost] + current
        return available.filter { state.allows($0) && (mediaFilter == .all || $0.isVideo == (mediaFilter == .video)) }
    }

    var body: some View {
        FeedPager(posts: posts, initialID: initialPost.id, isActive: true, loadsMore: source == .discover,
                  feedOverride: modeIsSelected && source == .discover ? modeFeed : nil)
            .background(.black)
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                        .background(FlowTheme.overlay, in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
                }.padding(16).accessibilityLabel("关闭全屏")
            }
            .overlay(alignment: .topTrailing) {
                MediaModeMenu(selection: Binding(get: { mediaFilter }, set: { modeIsSelected = true; mediaFilter = $0 })).padding(16)
            }
            .overlay { if source == .discover && modeIsSelected && modeFeed.isLoading { ProgressView().tint(.white) } }
            .preferredColorScheme(.dark)
            .onAppear {
                guard !initialized else { return }
                initialized = true
                if source == .library { savedSnapshot = (libraryPosts ?? state.library.posts(in: nil)).filter(state.allows) }
                else { mediaFilter = state.feed.query.media }
            }
            .task(id: FeedTaskID(query: modeQuery, revision: state.credentialRevision, enabled: modeIsSelected)) {
                guard source == .discover, modeIsSelected else { return }
                await modeFeed.refresh(query: modeQuery, token: state.token)
            }
    }
}

struct FeedPager: View {
    let posts: [MediaPost]
    let initialID: Int?
    let isActive: Bool
    let loadsMore: Bool
    let usesImmersiveFeed: Bool
    let feedOverride: FeedStore?
    private var feed: FeedStore { feedOverride ?? (usesImmersiveFeed ? state.immersiveFeed : state.feed) }
    @Environment(AppState.self) private var state
    @State private var focusedID: Int?
    @State private var notice: SuccessNotice?

    init(posts: [MediaPost], initialID: Int?, isActive: Bool, loadsMore: Bool, usesImmersiveFeed: Bool = false, feedOverride: FeedStore? = nil) {
        self.posts = posts
        self.initialID = initialID
        self.isActive = isActive
        self.loadsMore = loadsMore
        self.usesImmersiveFeed = usesImmersiveFeed
        self.feedOverride = feedOverride
        _focusedID = State(initialValue: initialID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(posts) { post in
                        MediaPage(post: post, isActive: isActive && focusedID == post.id) { text in
                            notice = SuccessNotice(text: text)
                        }
                        .containerRelativeFrame(.vertical)
                        .id(post.id)
                    }
                }.scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $focusedID)
            .background(.black)
            .clipped()
            .onChange(of: posts.map(\.id)) { _, ids in
                if !ids.contains(focusedID ?? -1) { focusedID = ids.first }
            }
            .overlay {
                if posts.isEmpty {
                    MessageState(title: "没有匹配的作品", message: "切换浏览模式，或调整内容等级。", symbol: "photo.on.rectangle",
                                 actionTitle: "继续加载", action: loadsMore && feed.hasMore ? { Task { await feed.loadMore(token: state.token) } } : nil)
                }
            }
            .task(id: focusedID) {
                if loadsMore, let post = posts.first(where: { $0.id == focusedID }) {
                    await feed.loadMoreIfNeeded(after: post, token: state.token)
                }
            }
            .overlay(alignment: .topTrailing) {
                if loadsMore, focusedID == posts.last?.id, feed.hasMore,
                   !feed.isLoadingMore, feed.errorMessage == nil {
                    Button("继续加载") { Task { await feed.loadMore(token: state.token) } }
                        .font(.caption.weight(.semibold)).padding(10)
                        .background(.black.opacity(0.5), in: Capsule()).padding(.top, 70).padding(.trailing, 18)
                }
            }
            .overlay(alignment: .top) {
                if loadsMore && feed.isLoadingMore { ProgressView().padding(.top, 65) }
                if loadsMore, let error = feed.errorMessage, !feed.isLoading {
                    Button { Task { await feed.loadMore(token: state.token) } } label: {
                        Text("\(error) 点此重试").font(.caption).padding(12).background(.ultraThinMaterial, in: Capsule())
                    }.padding(.top, 62).padding(.horizontal, 16)
                }
            }
            .task {
                await Task.yield()
                if let initialID { proxy.scrollTo(initialID, anchor: .top) }
            }
        }
        .successToast($notice)
    }
}

private struct MediaPage: View {
    let post: MediaPost
    let isActive: Bool
    let onSuccess: (String) -> Void
    @Environment(AppState.self) private var state
    @State private var promptPresented = false
    @State private var bookmarkPresented = false
    @State private var isSaving = false
    @State private var result: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                RatedMedia(post: post, isActive: isActive) { revealed in
                    if post.isVideo {
                        VideoSurface(url: post.url, poster: post.previewURL, isActive: isActive && revealed, isObscured: promptPresented || bookmarkPresented)
                    } else {
                        RemoteImage(url: post.url, fit: true)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack {
                    Spacer()
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(post.isVideo ? "MOTION / VIDEO" : "STILL / IMAGE")
                                .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.6).foregroundStyle(.white.opacity(0.65))
                            Text("@\(post.creator)").font(.title3.weight(.semibold))
                            Text(post.prompt ?? post.title).font(.subheadline).lineLimit(3).foregroundStyle(.white.opacity(0.8))
                            Button { promptPresented = true } label: {
                                Label("查看生成信息", systemImage: "text.viewfinder").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(FlowTheme.overlay, in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
                                    .overlay { RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
                            }.padding(.top, 4)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(spacing: 20) {
                            Button { bookmarkPresented = true } label: {
                                actionIcon(state.library.contains(post) ? "bookmark.fill" : "bookmark", label: "收藏")
                                    .foregroundStyle(state.library.contains(post) ? FlowTheme.accent : .white)
                            }.accessibilityLabel(state.library.contains(post) ? "管理收藏夹" : "收藏作品")
                            Link(destination: post.webURL) {
                                actionIcon("bubble.right", label: "评论")
                            }.accessibilityLabel("在 Civitai 查看评论")
                            ShareLink(item: post.webURL) { actionIcon("square.and.arrow.up", label: "分享") }
                            Menu {
                                Button("保存到相册", systemImage: "photo.badge.arrow.down") {
                                    isSaving = true
                                    Task {
                                        defer { isSaving = false }
                                        do { try await PhotoSaver.save(post); onSuccess("已保存到系统相册") }
                                        catch { result = error.localizedDescription }
                                    }
                                }
                                Button("下载到文件（含生成信息）", systemImage: "folder") {
                                    do {
                                        try state.downloads.enqueue(DownloadPlan.media(post), token: state.token)
                                        onSuccess("已加入下载队列")
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
        .background {
            RightSwipeCapture(enabled: isActive && !promptPresented && !bookmarkPresented) { bookmarkPresented = true }
        }
        .sensoryFeedback(.selection, trigger: bookmarkPresented)
        .sheet(isPresented: $bookmarkPresented) { BookmarkSheet(post: post) }
        .sheet(isPresented: $promptPresented) { PromptSheet(post: post) }
        .alert("提示", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("知道了", role: .cancel) { result = nil }
        } message: { Text(result ?? "") }
    }

    private func actionIcon(_ symbol: String, label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium)).frame(width: 44, height: 44)
                .background(FlowTheme.overlay, in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
            Text(label).font(.system(size: 10, weight: .medium))
        }.frame(minWidth: 44, minHeight: 44)
    }
}

struct MediaModeMenu: View {
    @Binding var selection: MediaFilter
    var body: some View {
        Menu {
            ForEach(MediaFilter.allCases, id: \.self) { mode in
                Button { selection = mode } label: {
                    Label(mode == .all ? "混合模式" : (mode == .image ? "仅图片" : "仅视频"), systemImage: selection == mode ? "checkmark.circle.fill" : (mode == .video ? "video" : "photo"))
                }
            }
        } label: {
            HStack(spacing: 6) {
                if selection == .all { Image("MediaMixed").renderingMode(.template).resizable().scaledToFit().frame(width: 24, height: 24) }
                else { Image(systemName: selection == .image ? "photo" : "video").frame(width: 24, height: 24) }
                Text(selection == .all ? "混合" : selection.title).font(.caption.weight(.semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }.foregroundStyle(.white).padding(.horizontal, 12).frame(minHeight: 44)
                .background(FlowTheme.overlay, in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
        }.accessibilityLabel("浏览模式：\(selection == .all ? "混合" : selection.title)")
    }
}

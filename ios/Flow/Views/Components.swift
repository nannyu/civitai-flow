import SwiftUI
import FlowCore

struct RemoteImage: View {
    let url: URL?
    var fit = false
    @State private var attempt = 0

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                if fit { image.resizable().scaledToFit() }
                else { image.resizable().scaledToFill() }
            case .failure:
                Button { attempt += 1 } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise").font(.title2)
                        Text("重新加载").font(.caption)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            default:
                ZStack {
                    Color.gray.opacity(0.12)
                    if url != nil { ProgressView().tint(.secondary) }
                    else { Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.secondary) }
                }
            }
        }.id(attempt)
    }
}

struct PostGrid: View {
    let posts: [MediaPost]
    let select: (MediaPost) -> Void
    var onAppear: (MediaPost) async -> Void = { _ in }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 18) {
            ForEach(posts) { post in
                Button { select(post) } label: { PostCard(post: post) }
                    .buttonStyle(.plain)
                    .task { await onAppear(post) }
            }
        }.padding(.horizontal, 16)
    }
}

struct PostCard: View {
    let post: MediaPost
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Color.clear
                .aspectRatio(0.76, contentMode: .fit)
                .overlay { RemoteImage(url: post.previewURL) }
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if post.isVideo {
                        Image(systemName: "play.fill").font(.caption2.bold()).padding(8)
                            .background(.black.opacity(0.45), in: Circle()).foregroundStyle(.white).padding(10)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if state.library.contains(post) {
                        Image(systemName: "bookmark.fill").font(.caption).padding(8)
                            .background(.ultraThinMaterial, in: Circle()).padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
            Text(post.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(FlowTheme.accent.opacity(0.12)).frame(width: 22, height: 22)
                    .overlay { Text(String(post.creator.prefix(1)).uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(FlowTheme.accent) }
                Text(post.creator).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "heart").font(.system(size: 10))
                Text((post.stats?.likeCount ?? 0).formatted(.number.notation(.compactName)))
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(post.creator) 的\(post.isVideo ? "视频" : "图片")，\(post.title)")
        .accessibilityHint("打开全屏浏览")
    }
}

struct MessageState: View {
    let title: String
    let message: String
    var symbol = "wifi.exclamationmark"
    var actionTitle = "重试"
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: { Text(message) } actions: {
            if let action { Button(actionTitle, action: action).buttonStyle(.borderedProminent) }
        }.padding(.vertical, 32)
    }
}

struct FeedFooter: View {
    @Environment(AppState.self) private var state
    var body: some View {
        VStack(spacing: 12) {
            if state.feed.isLoadingMore { ProgressView().padding() }
            else if let error = state.feed.errorMessage, !state.feed.posts.isEmpty {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("重试加载") { Task { await state.feed.loadMore(token: state.token) } }
            } else if state.feed.hasMore {
                Button("加载更多") { Task { await state.feed.loadMore(token: state.token) } }
                    .font(.subheadline)
            } else if !state.feed.posts.isEmpty {
                Text("已经看完了，换个筛选继续发现").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).padding(24)
    }
}

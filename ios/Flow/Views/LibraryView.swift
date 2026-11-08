import SwiftUI
import FlowCore

struct LibraryView: View {
    @Environment(AppState.self) private var state
    @State private var selection: MediaPost?
    @State private var search = ""

    private var posts: [MediaPost] {
        state.library.posts.filter {
            $0.isSafeForWork && (search.isEmpty || $0.creator.localizedCaseInsensitiveContains(search)
                || $0.title.localizedCaseInsensitiveContains(search) || ($0.prompt?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("值得留住的灵感").font(.title2.bold())
                            Text("\(state.library.posts.count) 个收藏 · 保存在这台设备")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "bookmark.fill").font(.title).foregroundStyle(FlowTheme.accent)
                    }.padding(20)
                    if let error = state.library.errorMessage {
                        MessageState(title: "收藏暂时不可用", message: error, symbol: "externaldrive.badge.exclamationmark")
                    } else if posts.isEmpty {
                        MessageState(title: search.isEmpty ? "收藏你的第一份灵感" : "没有找到匹配的收藏",
                                     message: search.isEmpty ? "在作品上轻点书签，之后就能在这里找到它。收藏的媒体仍需网络加载。" : "试试创作者、模型或提示词关键词。",
                                     symbol: "bookmark")
                    } else {
                        PostGrid(posts: posts, select: { selection = $0 })
                    }
                }.padding(.bottom, 24)
            }
            .background(FlowTheme.background)
            .navigationTitle("收藏").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜索我的收藏")
            .fullScreenCover(item: $selection) { post in DetailScreen(initialPost: post, source: .library) }
        }
    }
}

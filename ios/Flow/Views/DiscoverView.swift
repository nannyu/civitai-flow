import SwiftUI
import FlowCore

struct DiscoverView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var selection: MediaPost?
    @State private var showingFilters = false

    var body: some View {
        @Bindable var state = state
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introduction
                    HStack(spacing: 8) {
                        ForEach(MediaFilter.allCases, id: \.self) { filter in
                            Button { state.query.media = filter } label: {
                                Text(filter.title).font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 19).padding(.vertical, 10)
                                    .background(state.query.media == filter ? FlowTheme.accent : FlowTheme.surface, in: Capsule())
                                    .foregroundStyle(state.query.media == filter ? Color.white : Color.primary)
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        Button { showingFilters = true } label: {
                            Image(systemName: "line.3.horizontal.decrease").padding(12)
                                .background(FlowTheme.surface, in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel("排序与时间筛选")
                    }.padding(.horizontal, 16)

                    if state.feed.isLoading {
                        ProgressView("正在寻找灵感…").frame(maxWidth: .infinity).padding(.vertical, 80)
                    } else if state.feed.posts.isEmpty {
                        MessageState(title: state.feed.errorMessage == nil ? "这里还没有作品" : "暂时无法加载",
                                     message: state.feed.errorMessage ?? "试试其他创作者、时间范围，或继续加载下一页。",
                                     symbol: state.feed.errorMessage == nil ? "sparkles" : "wifi.exclamationmark") {
                            Task {
                                if state.feed.hasMore { await state.feed.loadMore(token: state.token) }
                                else { await state.feed.refresh(query: state.query, token: state.token) }
                            }
                        }
                    } else {
                        PostGrid(posts: state.feed.posts, select: { selection = $0 }) { post in
                            await state.feed.loadMoreIfNeeded(after: post, token: state.token)
                        }
                        FeedFooter()
                    }
                }.padding(.top, 12)
            }
            .background(FlowTheme.background)
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle").foregroundStyle(FlowTheme.accent)
                        Text("flow").font(.system(.title2, design: .rounded, weight: .heavy))
                    }.accessibilityLabel("Flow")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("CIVITAI").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $search, prompt: "输入 Civitai 创作者用户名")
            .onSubmit(of: .search) { state.query.username = search }
            .onChange(of: search) { _, value in if value.isEmpty { state.query.username = "" } }
            .refreshable { await state.feed.refresh(query: state.query, token: state.token) }
            .sheet(isPresented: $showingFilters) { FilterSheet() }
            .fullScreenCover(item: $selection) { post in DetailScreen(initialPost: post, source: .discover) }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("让灵感，自由流动。").font(.system(size: 28, weight: .bold, design: .rounded))
            HStack(spacing: 7) {
                Circle().fill(FlowTheme.accent).frame(width: 5, height: 5)
                Text(state.query.username.isEmpty ? "\(state.query.period.title)\(state.query.sort.title) · 来自 Civitai 创作者" : "来自 @\(state.query.username) 的作品")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 20).padding(.vertical, 8)
    }
}

struct FilterSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var state = state
        NavigationStack {
            Form {
                Picker("排序", selection: $state.query.sort) {
                    ForEach(FeedSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
                Picker("时间范围", selection: $state.query.period) {
                    ForEach(FeedPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }.navigationTitle("发现偏好").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

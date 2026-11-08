import SwiftUI
import FlowCore

struct DiscoverView: View {
    var isActive = true
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var searchTarget: SearchTarget = .models
    @State private var searchURL: URL?
    @State private var section: DiscoverSection = .home
    @State private var selection: MediaPost?
    @State private var showingFilters = false
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showingSearch { searchBar }
                navigationBar
                if let searchURL {
                    CivitaiWebView(url: searchURL, isActive: isActive)
                } else if !section.isNative {
                    CivitaiWebView(url: section.url, isActive: isActive)
                } else {
                    mediaFeed
                }
            }
            .background(FlowTheme.background)
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    FlowBrand().fixedSize(horizontal: true, vertical: false)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showingSearch.toggle() }
                        searchFocused = showingSearch
                        if !showingSearch { searchURL = nil; search = "" }
                    } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }
                        .accessibilityLabel(showingSearch ? "关闭搜索" : "搜索 Civitai")
                }
            }
            .onChange(of: section) { _, value in
                searchURL = nil
                if value.isNative { state.query.media = value.media }
            }
            .sheet(isPresented: $showingFilters) { FilterSheet(section: $section) }
            .fullScreenCover(item: $selection) { DetailScreen(initialPost: $0, source: .discover) }
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(DiscoverSection.allCases, id: \.self) { item in
                        Button {
                            section = item; searchURL = nil
                            if item.isNative { state.query.media = item.media }
                        } label: {
                            Text(item.title)
                        }.buttonStyle(FlowChipStyle(selected: section == item && searchURL == nil))
                            .accessibilityAddTraits(section == item && searchURL == nil ? .isSelected : [])
                    }
                }
            }.scrollIndicators(.hidden)
            Button { showingFilters = true } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }.buttonStyle(FlowIconButtonStyle()).accessibilityLabel("排序与时间筛选")
        }.padding(.horizontal, FlowTheme.pageInset).padding(.vertical, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(SearchTarget.allCases, id: \.self) { target in
                    Button {
                        searchTarget = target
                        if searchURL != nil { submitSearch() }
                    } label: {
                        if target == searchTarget { Label(target.title, systemImage: "checkmark") }
                        else { Text(target.title) }
                    }
                }
            } label: {
                HStack(spacing: 4) { Text(searchTarget.title); Image(systemName: "chevron.down").font(.caption2) }
                    .font(.subheadline.weight(.semibold))
            }.foregroundStyle(FlowTheme.accent).accessibilityLabel("搜索类型：\(searchTarget.title)")
            Rectangle().fill(FlowTheme.line).frame(width: 1, height: 20).accessibilityHidden(true)
            TextField("搜索 \(searchTarget.title)…", text: $search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($searchFocused).onSubmit { submitSearch() }
            if !search.isEmpty {
                Button { search = ""; searchURL = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("清除搜索")
            }
            Button(action: submitSearch) { Image(systemName: "arrow.right.circle.fill").font(.title2) }
                .disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("开始搜索")
        }.padding(.horizontal, 14).frame(minHeight: 52)
            .background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous).strokeBorder(FlowTheme.line, lineWidth: 0.5) }
            .padding(.horizontal, FlowTheme.pageInset).padding(.top, 8)
    }

    private func submitSearch() {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchURL = searchTarget.url(query: search)
        searchFocused = false
    }

    private var mediaFeed: some View {
        ScrollView {
            VStack(spacing: 18) {
                if state.feed.isLoading {
                    ProgressView("正在加载…").frame(maxWidth: .infinity).padding(.vertical, 80)
                } else if state.feed.posts.isEmpty {
                    MessageState(title: state.feed.errorMessage == nil ? "这里还没有作品" : "暂时无法加载",
                                 message: state.feed.errorMessage ?? "试试其他内容等级、时间范围，或继续加载下一页。",
                                 symbol: state.feed.errorMessage == nil ? "sparkles" : "wifi.exclamationmark") {
                        Task {
                            if state.feed.hasMore { await state.feed.loadMore(token: state.token) }
                            else { await state.feed.refresh(query: state.query, token: state.token) }
                        }
                    }
                } else {
                    PostGrid(posts: state.feed.posts.filter(state.allows), select: { selection = $0 }, isActive: isActive && selection == nil && !showingFilters) { post in
                        await state.feed.loadMoreIfNeeded(after: post, token: state.token)
                    }
                    FeedFooter()
                }
            }.padding(.top, 8)
        }
        .refreshable { await state.feed.refresh(query: state.query, token: state.token) }
    }
}

struct FilterSheet: View {
    @Binding var section: DiscoverSection
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var state = state
        NavigationStack {
            Form {
                Picker("分类", selection: $section) {
                    ForEach(DiscoverSection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Section("图片与视频排序") {
                Picker("排序", selection: $state.query.sort) {
                    ForEach(FeedSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
                Picker("时间范围", selection: $state.query.period) {
                    ForEach(FeedPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                }.disabled(!section.isNative)
                if !section.isNative { Text("此分类使用 Civitai 页面，可在页面内调整等级与排序。").font(.footnote).foregroundStyle(.secondary) }
            }.flowListSurface().navigationTitle("发现偏好").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

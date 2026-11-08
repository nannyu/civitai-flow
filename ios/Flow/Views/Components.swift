import SwiftUI
import FlowCore
import WebKit

struct FlowLogo: View {
    var size: CGFloat = 32
    var body: some View {
        Image("FlowLogo").resizable().scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct FlowBrand: View {
    var onDark = false
    var body: some View {
        HStack(spacing: 8) {
            FlowLogo(size: 28)
            Text("flow").font(.system(.title3, design: .rounded, weight: .semibold)).tracking(-0.7)
                .foregroundStyle(onDark ? .white : FlowTheme.ink)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Flow")
    }
}

struct FlowChipStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(selected ? .semibold : .medium))
            .padding(.horizontal, 14).frame(minHeight: 44)
            .foregroundStyle(selected ? FlowTheme.accent : FlowTheme.muted)
            .background(selected ? FlowTheme.accentSoft : FlowTheme.surface,
                        in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous)
                    .strokeBorder(selected ? FlowTheme.accent.opacity(0.2) : FlowTheme.line, lineWidth: 0.5)
            }
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct FlowIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .medium))
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(FlowTheme.ink)
            .background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous)
                    .strokeBorder(FlowTheme.line, lineWidth: 0.5)
            }.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct FlowPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18).frame(minHeight: 44)
            .foregroundStyle(FlowTheme.onAccent)
            .background(FlowTheme.accent, in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.7 : 1))
    }
}

extension View {
    func flowListSurface() -> some View {
        scrollContentBackground(.hidden)
            .background(FlowTheme.background)
            .listSectionSpacing(20)
            .environment(\.defaultMinListRowHeight, 50)
    }
    func flowPanel() -> some View {
        background(FlowTheme.surface, in: RoundedRectangle(cornerRadius: FlowTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlowTheme.cardRadius, style: .continuous)
                    .strokeBorder(FlowTheme.line, lineWidth: 0.5)
            }
    }
}

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
                    FlowTheme.inset
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
    var isActive = true
    var onAppear: (MediaPost) async -> Void = { _ in }
    @State private var playingID: Int?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 22) {
            ForEach(posts) { post in
                PostCard(post: post, select: { select(post) }, isActive: isActive, playingInline: Binding(
                    get: { playingID == post.id },
                    set: { value in if value { playingID = post.id } else if playingID == post.id { playingID = nil } }
                ))
                    .task { await onAppear(post) }
            }
        }.padding(.horizontal, FlowTheme.pageInset)
            .onChange(of: isActive) { _, active in if !active { playingID = nil } }
            .onDisappear { playingID = nil }
    }
}

struct PostCard: View {
    let post: MediaPost
    let select: () -> Void
    var isActive = true
    @Environment(AppState.self) private var state
    @Binding var playingInline: Bool
    @State private var bookmarkPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RatedMedia(post: post, isActive: isActive) { revealed in
                ZStack(alignment: .topTrailing) {
                    Button(action: select) {
                        Color.clear
                            .aspectRatio(0.76, contentMode: .fit)
                            .overlay {
                                if post.isVideo && playingInline && revealed {
                                    VideoSurface(url: post.url, poster: post.previewURL, isActive: isActive, isObscured: bookmarkPresented, compact: true, startOnRequest: true)
                                        .allowsHitTesting(false)
                                } else { RemoteImage(url: post.previewURL) }
                            }
                            .clipped()
                            .overlay(alignment: .bottomLeading) {
                                if state.library.contains(post) {
                                    Image(systemName: "bookmark.fill").font(.caption).padding(8)
                                        .background(.ultraThinMaterial, in: Circle()).padding(10)
                                }
                            }
                    }.buttonStyle(.plain).accessibilityLabel("打开 \(post.creator) 的\(post.isVideo ? "视频" : "图片")")
                    if post.isVideo {
                        Button { playingInline.toggle() } label: {
                            Image(systemName: playingInline ? "pause.fill" : "play.fill")
                                .font(.caption.bold()).frame(width: 44, height: 44)
                                .background(FlowTheme.overlay, in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous)).foregroundStyle(.white)
                        }.buttonStyle(.plain).padding(8)
                            .accessibilityLabel(playingInline ? "停止卡片播放" : "在当前页面播放")
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FlowTheme.cardRadius, style: .continuous))
            .onDisappear { playingInline = false }
            .onChange(of: isActive) { _, active in if !active { playingInline = false } }
            .contextMenu {
                Button("选择收藏夹", systemImage: "bookmark") { bookmarkPresented = true }
            }
            Button(action: select) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(post.title).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(FlowTheme.ink)
                    HStack(spacing: 5) {
                        Circle().fill(FlowTheme.accentSoft).frame(width: 20, height: 20)
                            .overlay { Text(String(post.creator.prefix(1)).uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(FlowTheme.accent) }
                        Text(post.creator).lineLimit(1)
                        Spacer(minLength: 0)
                        if let rating = post.contentRating { Text(rating.title).font(.system(size: 9, weight: .medium)) }
                        Image(systemName: "heart").font(.system(size: 10))
                        Text((post.stats?.likeCount ?? 0).formatted(.number.notation(.compactName)))
                    }.font(.caption2).foregroundStyle(FlowTheme.muted)
                }
            }.buttonStyle(.plain)
        }
        .sheet(isPresented: $bookmarkPresented) { BookmarkSheet(post: post) }
    }
}

/// Shared by cards and fullscreen media so a blurred video cannot start playing underneath.
struct RatedMedia<Content: View>: View {
    let post: MediaPost
    var isActive = true
    @ViewBuilder let content: (Bool) -> Content
    @AppStorage("blurMature") private var blurMature = true
    @State private var revealed = false
    private var covered: Bool { blurMature && post.contentRating?.isMature == true && !revealed }

    var body: some View {
        content(!covered)
            .blur(radius: covered ? 28 : 0)
            .allowsHitTesting(!covered)
            .overlay {
                if covered {
                    Button { revealed = true } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "eye.slash").font(.title2)
                            Text("\(post.contentRating?.title ?? "R+") · 轻点查看").font(.caption.weight(.semibold))
                        }.padding(18).foregroundStyle(.white)
                            .background(FlowTheme.overlay, in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
                    }.buttonStyle(.plain).accessibilityLabel("显示已模糊的 \(post.contentRating?.title ?? "R+") 内容")
                }
            }
            .onChange(of: isActive) { _, active in if !active { revealed = false } }
            .onDisappear { revealed = false }
            .onChange(of: blurMature) { _, _ in revealed = false }
            .onChange(of: post.id) { _, _ in revealed = false }
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
            Label {
                Text(title).foregroundStyle(FlowTheme.ink)
            } icon: {
                Image(systemName: symbol).foregroundStyle(FlowTheme.accent)
            }
        } description: { Text(message).foregroundStyle(FlowTheme.muted) } actions: {
            if let action { Button(actionTitle, action: action).buttonStyle(FlowPrimaryButtonStyle()) }
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

/// Full site sections and typed search stay in-app, without exposing the Keychain token to web content.
struct CivitaiWebView: View {
    let url: URL
    var isActive = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var browser = SiteBrowser()
    var body: some View {
        VStack(spacing: 0) {
            if browser.loading { ProgressView().frame(maxWidth: .infinity).padding(10) }
            if let error = browser.error {
                MessageState(title: "页面暂时无法加载", message: error) { browser.reload() }
            }
            SiteWebSurface(browser: browser, url: url, isActive: isActive && scenePhase == .active)
            HStack {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 36) }.disabled(!browser.canGoBack)
                Spacer()
                Text(browser.host).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { browser.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 36) }.accessibilityLabel("重新加载网页")
            }.padding(.horizontal, 12).background(FlowTheme.surface)
        }
        .onAppear { browser.setActive(isActive && scenePhase == .active) }
        .onDisappear { browser.setActive(false) }
    }
}

@MainActor @Observable
private final class SiteBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var loading = true
    var error: String?
    var canGoBack = false
    var host = "civitai.red"
    @ObservationIgnored var requestedURL: URL?
    @ObservationIgnored private var active: Bool?
    @ObservationIgnored private var historyObservation: NSKeyValueObservation?
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        historyObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.canGoBack = self.webView.canGoBack
            }
        }
    }
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        webView.setAllMediaPlaybackSuspended(!value, completionHandler: nil)
    }
    func reload() {
        error = nil
        if webView.url == nil, let requestedURL { webView.load(URLRequest(url: requestedURL)) }
        else { webView.reload() }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; canGoBack = webView.canGoBack; host = webView.url?.host ?? "civitai.red" }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { loading = false; self.error = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { loading = false; self.error = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loading = false; error = "页面进程已结束，请重新加载。" }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["https", "http"].contains(url.scheme) { webView.load(URLRequest(url: url)) }
        return nil
    }
}

private struct SiteWebSurface: UIViewRepresentable {
    let browser: SiteBrowser
    let url: URL
    let isActive: Bool
    func makeCoordinator() -> SiteBrowser { browser }
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        browser.setActive(isActive)
        guard browser.requestedURL != url else { return }
        browser.requestedURL = url
        uiView.load(URLRequest(url: url))
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: SiteBrowser) {
        uiView.stopLoading()
        coordinator.setActive(false)
    }
}

/// Reject vertical drags before recognition so the enclosing paging scroll view keeps them.
struct RightSwipeCapture: UIViewRepresentable {
    let enabled: Bool
    let action: () -> Void
    func makeUIView(context: Context) -> HorizontalSwipeView {
        let view = HorizontalSwipeView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: HorizontalSwipeView, context: Context) {
        view.enabled = enabled
        view.action = action
    }
    static func dismantleUIView(_ view: HorizontalSwipeView, coordinator: ()) { view.detach() }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HorizontalSwipeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

final class HorizontalSwipeView: UIView, UIGestureRecognizerDelegate {
    var enabled = false { didSet { swipe.isEnabled = enabled } }
    var action: (() -> Void)?
    private weak var gestureHost: UIView?
    private lazy var swipe: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        gesture.delegate = self
        gesture.cancelsTouchesInView = false
        return gesture
    }()
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detach() }
        else { DispatchQueue.main.async { [weak self] in self?.attach() } }
    }
    private func attach() {
        guard let window, gestureHost == nil else { return }
        window.addGestureRecognizer(swipe)
        gestureHost = window
    }
    func detach() { gestureHost?.removeGestureRecognizer(swipe); gestureHost = nil }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard enabled, gestureHost === window, bounds.contains(touch.location(in: self)) else { return false }
        var touched = touch.view
        while let view = touched {
            if view is UIControl { return false }
            touched = view.superview
        }
        return true
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = swipe.velocity(in: gestureHost)
        return enabled && bounds.contains(swipe.location(in: self))
            && velocity.x > 0 && velocity.x > abs(velocity.y) * 1.6
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    @objc private func handleSwipe(_ gesture: UIPanGestureRecognizer) {
        guard enabled, gesture.state == .ended else { return }
        let distance = gesture.translation(in: gestureHost)
        if distance.x > 85 && distance.x > abs(distance.y) * 1.6 { action?() }
    }
}

struct SuccessNotice: Identifiable {
    let id = UUID()
    let text: String
}

extension View {
    func successToast(_ notice: Binding<SuccessNotice?>) -> some View {
        modifier(SuccessToast(notice: notice))
    }
}

private struct SuccessToast: ViewModifier {
    @Binding var notice: SuccessNotice?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice {
                    Label(notice.text, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                        .padding(.horizontal, 24).padding(.bottom, 20)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: notice?.id)
            .task(id: notice?.id) {
                guard let current = notice else { return }
                UIAccessibility.post(notification: .announcement, argument: current.text)
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard notice?.id == current.id else { return }
                notice = nil
            }
    }
}

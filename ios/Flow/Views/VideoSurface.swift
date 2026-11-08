import SwiftUI
import AVFoundation
import UIKit

@MainActor
private final class VideoPlayback: ObservableObject {
    @Published var player: AVQueuePlayer?
    @Published var error: String?
    @Published var ready = false
    private var looper: AVPlayerLooper?
    private var observation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var failureObservation: NSKeyValueObservation?
    private var generation = UUID()

    func load(_ url: URL, muted: Bool) {
        guard player == nil else { return }
        let current = UUID()
        generation = current
        error = nil
        ready = false
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = muted
        queue.automaticallyWaitsToMinimizeStalling = true
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
        observation = queue.observe(\.status, options: [.new]) { [weak self] player, _ in
            guard player.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard self?.generation == current else { return }
                self?.error = "视频播放失败，请检查网络后重试。"
            }
        }
        itemObservation = queue.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.player?.currentItem === item else { return }
                self.failureObservation = item?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let status = item.status
                    Task { @MainActor [weak self] in
                        guard self?.generation == current, self?.player?.currentItem === item else { return }
                        self?.ready = status == .readyToPlay
                        if status == .failed { self?.error = "此视频暂时无法播放，可在 Civitai 查看原作品。" }
                    }
                }
            }
        }
    }

    func unload() {
        generation = UUID()
        player?.pause()
        observation?.invalidate()
        observation = nil
        itemObservation?.invalidate()
        itemObservation = nil
        failureObservation?.invalidate()
        failureObservation = nil
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        ready = false
        error = nil
    }
}

private final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer?
    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: PlayerHostView, context: Context) { view.playerLayer.player = player }
    static func dismantleUIView(_ view: PlayerHostView, coordinator: ()) { view.playerLayer.player = nil }
}

struct VideoSurface: View {
    let url: URL
    let poster: URL?
    let isActive: Bool
    var isObscured = false
    var compact = false
    var startOnRequest = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("muted") private var muted = true
    @StateObject private var playback = VideoPlayback()
    @State private var manuallyPaused = false

    var body: some View {
        ZStack {
            RemoteImage(url: poster, fit: true)
            if playback.player != nil {
                PlayerLayer(player: playback.player)
                    .opacity(playback.ready ? 1 : 0)
                    .onTapGesture { manuallyPaused.toggle(); updatePlayback() }
                    .accessibilityLabel(manuallyPaused ? "播放视频" : "暂停视频")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { manuallyPaused.toggle(); updatePlayback() }
            }
            if isActive && !playback.ready && playback.error == nil { ProgressView().tint(.white) }
            if let error = playback.error {
                VStack(spacing: 14) {
                    Text(error).font(.subheadline)
                    Button("重试") { playback.unload(); updatePlayback() }.buttonStyle(.bordered)
                }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if manuallyPaused && isActive {
                Button { manuallyPaused = false; updatePlayback() } label: {
                    Image(systemName: "play.fill").font(.system(size: 36)).padding(28)
                        .background(.black.opacity(0.35), in: Circle())
                }.accessibilityLabel("播放视频")
            }
        }
        .overlay(alignment: .topTrailing) {
            if !compact { Button { muted.toggle() } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 44, height: 44).background(FlowTheme.overlay, in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
            }.accessibilityLabel(muted ? "开启声音" : "静音").padding(.top, 70).padding(.trailing, 20) }
        }
        .foregroundStyle(.white)
        .onAppear { manuallyPaused = !startOnRequest && !autoplay; updatePlayback() }
        .onChange(of: isActive) { _, active in
            if active { manuallyPaused = !startOnRequest && !autoplay }
            updatePlayback()
        }
        .onChange(of: scenePhase) { _, _ in updatePlayback() }
        .onChange(of: isObscured) { _, _ in updatePlayback() }
        .onChange(of: url) { _, _ in playback.unload(); updatePlayback() }
        .onChange(of: muted) { _, value in playback.player?.isMuted = value }
        .onChange(of: autoplay) { _, value in
            if !startOnRequest { manuallyPaused = !value; updatePlayback() }
        }
        .onDisappear { playback.unload() }
    }

    private func updatePlayback() {
        guard isActive else { playback.unload(); return }
        playback.load(url, muted: muted)
        if scenePhase == .active && !isObscured && !manuallyPaused { playback.player?.play() }
        else { playback.player?.pause() }
    }
}

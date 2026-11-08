import SwiftUI
import UIKit
import FlowCore
import QuickLook
import AVKit
import ImageIO

struct DownloadsView: View {
    @Environment(AppState.self) private var state
    @State private var addingModel = false
    @State private var export: DownloadExport?
    @State private var message: String?
    @State private var removing: DownloadRecord?
    @State private var viewing: DownloadExport?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { addingModel = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "link.badge.plus").font(.title3.weight(.medium))
                                .frame(width: 44, height: 44).background(FlowTheme.accentSoft, in: RoundedRectangle(cornerRadius: FlowTheme.controlRadius, style: .continuous))
                            Text("粘贴模型链接下载").font(.subheadline.weight(.semibold)).foregroundStyle(FlowTheme.ink)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(FlowTheme.muted)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                } footer: {
                    Text("模型文件、预览和生成信息保存在本机。下载时请保持 Flow 在前台；中断后可重新下载。")
                }.listRowBackground(FlowTheme.surface)
                if let error = state.downloads.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if state.downloads.records.isEmpty {
                    MessageState(title: "还没有下载", message: "粘贴 Civitai 模型链接，或在作品中选择“下载到文件”。", symbol: "arrow.down.circle")
                        .listRowBackground(Color.clear)
                }
                ForEach(state.downloads.records) { record in
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(record.plan.title).font(.headline).textSelection(.enabled)
                            Label(statusTitle(record.status), systemImage: statusSymbol(record.status))
                                .font(.caption.weight(.medium)).foregroundStyle(record.status == .completed ? FlowTheme.accent : FlowTheme.muted)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(record.status == .completed ? FlowTheme.accentSoft : FlowTheme.inset, in: Capsule())
                            if record.status == .downloading {
                                Text(state.downloads.currentFilename ?? "准备下载…").font(.caption).lineLimit(2)
                                if let progress = state.downloads.progress {
                                    if let fraction = progress.fraction { ProgressView(value: fraction) }
                                    else { ProgressView() }
                                    Text(progressText(progress)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                } else { ProgressView() }
                            }
                            if let error = record.error { Text(error).font(.caption).foregroundStyle(.red) }
                            if record.status == .completed {
                                ForEach(record.files, id: \.self) { name in
                                    Button { perform {
                                        let urls = try state.downloads.fileURLs(for: record)
                                        viewing = DownloadExport(urls: urls, initialURL: urls.first { $0.lastPathComponent == name }, plan: record.plan)
                                    } } label: {
                                        Label(name, systemImage: "doc").font(.caption)
                                    }.buttonStyle(.borderless)
                                }
                                ForEach(record.plan.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }
                            HStack(spacing: 20) {
                                if record.status == .queued || record.status == .downloading {
                                    Button("取消", role: .cancel) { state.downloads.cancel(record.id) }
                                } else {
                                    if record.status == .completed {
                                        Button { perform { viewing = DownloadExport(urls: try state.downloads.fileURLs(for: record), plan: record.plan) } } label: {
                                            Label("查看内容", systemImage: "eye")
                                        }
                                        Button { perform { export = DownloadExport(urls: try state.downloads.fileURLs(for: record)) } } label: {
                                            Label("导出到文件", systemImage: "square.and.arrow.up")
                                        }
                                    } else {
                                        Button("重试") { perform { try state.downloads.retry(record.id, token: state.token) } }
                                    }
                                    Spacer()
                                    Button("删除", role: .destructive) { removing = record }
                                }
                            }.font(.subheadline).buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }.listRowBackground(FlowTheme.surface)
                }
            }
            .flowListSurface()
            .navigationTitle("下载").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $addingModel) { ModelDownloadSheet() }
            .sheet(item: $export) { FileExportSheet(urls: $0.urls) }
            .sheet(item: $viewing) { DownloadContentView(urls: $0.urls, initialURL: $0.initialURL, plan: $0.plan) }
            .confirmationDialog("删除此下载及本机文件？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("删除下载", role: .destructive) {
                    if let removing { perform { try state.downloads.remove(removing.id) } }
                    removing = nil
                }
            }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("知道了", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
        }
    }

    private func perform(_ action: () throws -> Void) { do { try action() } catch { message = error.localizedDescription } }
    private func statusTitle(_ status: DownloadRecord.Status) -> String {
        switch status {
        case .queued: return "等待下载"
        case .downloading: return "下载中"
        case .completed: return "已下载到本机"
        case .failed: return "下载失败"
        case .cancelled: return "已取消"
        }
    }
    private func statusSymbol(_ status: DownloadRecord.Status) -> String {
        switch status {
        case .queued: return "clock"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }
    private func progressText(_ value: DownloadProgress) -> String {
        let received = ByteCountFormatter.string(fromByteCount: value.received, countStyle: .file)
        guard value.expected > 0 else { return received }
        return "\(received) / \(ByteCountFormatter.string(fromByteCount: value.expected, countStyle: .file))"
    }
}

private struct DownloadExport: Identifiable { let id = UUID(); let urls: [URL]; var initialURL: URL? = nil; var plan: DownloadPlan? = nil }
private struct FileExportSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

struct ModelDownloadSheet: View {
    let initialLink: String
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var catalog: ModelCatalog?
    @State private var document: ModelVersionDocument?
    @State private var versionID: Int?
    @State private var fileID: Int?
    @State private var options = DownloadOptions()
    @State private var loading = false
    @State private var message: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var generation = UUID()

    init(initialLink: String = "") {
        self.initialLink = initialLink
        _input = State(initialValue: initialLink)
    }

    private var selectedFile: ModelFile? { document?.version.downloadableFiles.first { $0.id == fileID } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://civitai.com/models/…", text: $input, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("读取模型信息") { resolve() }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: { Text("Civitai 模型链接") } footer: {
                    Text("支持模型页面、带 modelVersionId 的链接和 /api/download/models/ 下载链接。")
                }
                if loading { Section { ProgressView("读取模型信息…") } }
                if let message {
                    Section {
                        Text(message).foregroundStyle(.red)
                        if document == nil, !loading {
                            Button("重试读取") { if let versionID { loadVersion(versionID) } else { resolve() } }
                        }
                    }
                }
                if let catalog {
                    Section(catalog.name) {
                        Picker("模型版本", selection: $versionID) {
                            ForEach(catalog.modelVersions) { version in Text(version.name).tag(Optional(version.id)) }
                        }.disabled(loading)
                    }
                }
                if let document, !loading {
                    Section(document.version.name) {
                        if let base = document.version.baseModel { LabeledContent("基础模型", value: base) }
                        ForEach(document.version.downloadableFiles) { file in
                            Button { fileID = file.id } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: fileID == file.id ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.name).foregroundStyle(.primary)
                                        Text(fileDetails(file)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if document.version.downloadableFiles.isEmpty { Text("此版本没有可下载文件。") }
                    }
                    Section {
                        Toggle("下载预览文件", isOn: $options.includePreview)
                        if options.includePreview { Toggle("预览仅选择图片", isOn: $options.imagePreviewOnly) }
                        Toggle("保存描述文本", isOn: $options.includeDescription)
                        Label("同时保存完整版本元数据", systemImage: "doc.text")
                    } header: { Text("配套文件") } footer: {
                        Text("每次下载使用独立文件夹。预览遵循设置中选择的内容等级；缺少预览或描述时会跳过。")
                    }
                    Section {
                        Button {
                            guard let file = selectedFile else { return }
                            do {
                                var configured = options
                                configured.ratings = state.ratings
                                let plan = try DownloadPlan.model(document, file: file, modelDescription: catalog?.description, options: configured)
                                try state.downloads.enqueue(plan, token: state.token)
                                dismiss()
                            } catch { message = error.localizedDescription }
                        } label: { Label("加入下载", systemImage: "arrow.down.circle.fill") }
                        .buttonStyle(FlowPrimaryButtonStyle())
                        .disabled(selectedFile == nil)
                    } footer: { Text("受限模型需要在设置中填写具有下载权限的 API Key。大文件请预留足够空间。") }
                }
            }
            .flowListSurface()
            .navigationTitle("下载模型").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear { if document == nil, !initialLink.isEmpty { resolve() } }
            .onDisappear { loadTask?.cancel() }
            .onChange(of: versionID) { _, id in
                if let id, !loading, id != document?.version.id { loadVersion(id) }
            }
            .onChange(of: input) { _, _ in
                loadTask?.cancel(); generation = UUID(); loading = false
                catalog = nil; document = nil; versionID = nil; fileID = nil; message = nil
            }
        }
    }

    private func resolve() {
        loadTask?.cancel()
        let requestID = UUID()
        generation = requestID
        loading = true; message = nil; document = nil; catalog = nil; versionID = nil; fileID = nil
        let input = input
        loadTask = Task { @MainActor in
            defer { if generation == requestID { loading = false } }
            do {
                let link = try ModelLink(input)
                let client = ModelClient()
                let result: ModelCatalog?
                if let id = link.modelID { result = try await client.catalog(id: id, token: state.token) }
                else { result = nil }
                guard let selectedID = link.versionID ?? result?.modelVersions.first?.id else { throw DownloadError.noFiles }
                if let result, !result.modelVersions.contains(where: { $0.id == selectedID }) { throw DownloadError.invalidLink }
                let version = try await client.version(id: selectedID, token: state.token)
                try Task.checkCancellation()
                guard generation == requestID else { return }
                catalog = result; document = version; versionID = selectedID
                let files = version.version.downloadableFiles
                if link.fileQuery.isEmpty {
                    fileID = files.first(where: { $0.primary == true })?.id ?? files.first?.id
                } else {
                    fileID = files.first(where: { $0.matches(link.fileQuery) })?.id
                    if fileID == nil { message = "链接指定的文件当前不可用，请从下方选择文件。" }
                }
            } catch {
                if !Task.isCancelled, generation == requestID { message = error.localizedDescription }
            }
        }
    }

    private func loadVersion(_ id: Int) {
        loadTask?.cancel()
        let requestID = UUID(); generation = requestID
        loading = true; message = nil; document = nil; fileID = nil
        loadTask = Task { @MainActor in
            defer { if generation == requestID { loading = false } }
            do {
                let result = try await ModelClient().version(id: id, token: state.token)
                try Task.checkCancellation()
                guard generation == requestID else { return }
                document = result
                fileID = result.version.downloadableFiles.first(where: { $0.primary == true })?.id ?? result.version.downloadableFiles.first?.id
            } catch { if !Task.isCancelled, generation == requestID { message = error.localizedDescription } }
        }
    }

    private func fileDetails(_ file: ModelFile) -> String {
        var parts = [file.type]
        if let size = file.sizeKB, size.isFinite, size > 0, size < Double(Int64.max) / 1024 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size * 1024), countStyle: .file))
        }
        if let metadata = file.metadata {
            parts += ["format", "size", "fp"].compactMap { metadata[$0]?.text }.filter { !$0.isEmpty }
        }
        return parts.joined(separator: " · ")
    }
}

private struct DownloadContentView: View {
    let urls: [URL]
    var initialURL: URL?
    var plan: DownloadPlan?
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("muted") private var muted = true
    @AppStorage("blurMature") private var blurMature = true
    @State private var selected: URL?
    @State private var quickLook: URL?
    @State private var player: AVPlayer?
    @State private var playerObservation: NSKeyValueObservation?
    @State private var playbackError: String?
    @State private var revealed: URL?
    @State private var selectedRating: ContentRating?
    @State private var previewImage: UIImage?
    private var canPreviewSelected: Bool {
        guard let selectedRating else { return true }
        return state.ratings & selectedRating.rawValue != 0 && (!selectedRating.isMature || !blurMature || revealed == selected)
    }
    private let imageExtensions = ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic"]
    private let videoExtensions = ["mp4", "mov", "webm"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let selected {
                        if let rating = selectedRating, state.ratings & rating.rawValue == 0 {
                            ContentUnavailableView("内容等级未选中", systemImage: "eye.slash", description: Text("此文件为 \(rating.title)，可在设置中调整内容等级。"))
                        } else if let rating = selectedRating, rating.isMature && blurMature && revealed != selected {
                            Button { revealed = selected; show(selected) } label: {
                                Label("\(rating.title) · 轻点查看", systemImage: "eye.slash").padding(28)
                            }.frame(minHeight: 280)
                        } else if videoExtensions.contains(selected.pathExtension.lowercased()) {
                            if let playbackError {
                                MessageState(title: "无法预览视频", message: playbackError, symbol: "video.slash")
                            } else { VideoPlayer(player: player).frame(minHeight: 300).background(.black) }
                        } else if let image = previewImage {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 480)
                        } else if imageExtensions.contains(selected.pathExtension.lowercased()) {
                            ContentUnavailableView("无法预览图片", systemImage: "photo", description: Text("可尝试系统预览，或导出原文件。"))
                        } else if let text = readableText(selected) {
                            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding()
                        } else {
                            ContentUnavailableView(selected.lastPathComponent, systemImage: "doc", description: Text("模型文件已保存在本机，可导出到支持此格式的应用。"))
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(urls, id: \.self) { url in
                            Button { show(url) } label: {
                                HStack {
                                    Image(systemName: videoExtensions.contains(url.pathExtension.lowercased()) ? "play.rectangle" : "doc")
                                    Text(url.lastPathComponent).font(.subheadline).multilineTextAlignment(.leading)
                                    Spacer()
                                    if selected == url { Image(systemName: "checkmark") }
                                }.padding(14).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }.flowPanel()
                    if let selected {
                        HStack(spacing: 24) {
                            Button("系统预览") { quickLook = selected }.disabled(!canPreviewSelected)
                            ShareLink(item: selected) { Label("分享文件", systemImage: "square.and.arrow.up") }
                        }.font(.subheadline)
                    }
                }.padding(FlowTheme.pageInset)
            }.background(FlowTheme.background)
                .navigationTitle("已下载内容").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .quickLookPreview($quickLook)
                .onAppear { show(initialURL ?? urls.first(where: { imageExtensions.contains($0.pathExtension.lowercased()) || videoExtensions.contains($0.pathExtension.lowercased()) }) ?? urls.first) }
                .onDisappear { playerObservation?.invalidate(); playerObservation = nil; player?.pause(); player = nil }
                .onChange(of: scenePhase) { _, phase in if phase != .active { player?.pause() } }
                .onChange(of: quickLook) { _, value in if value != nil { player?.pause() } }
                .onChange(of: muted) { _, value in player?.isMuted = value }
                .onChange(of: blurMature) { _, _ in revealed = nil; show(selected) }
                .onChange(of: state.ratings) { _, _ in revealed = nil; show(selected) }
        }
    }
    private func show(_ url: URL?) {
        playerObservation?.invalidate(); playerObservation = nil
        player?.pause(); player = nil; selected = url; playbackError = nil; previewImage = nil
        selectedRating = url.flatMap { plan?.contentRating(for: $0.lastPathComponent) }
        if let url, let rating = selectedRating {
            guard state.ratings & rating.rawValue != 0, !rating.isMature || !blurMature || revealed == url else { return }
        }
        if let url, videoExtensions.contains(url.pathExtension.lowercased()) {
            let item = AVPlayerItem(url: url)
            let newPlayer = AVPlayer(playerItem: item); newPlayer.isMuted = muted; player = newPlayer
            playerObservation = item.observe(\.status, options: [.initial, .new]) { [weak newPlayer] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in
                    guard selected == url, player === newPlayer else { return }
                    playbackError = "系统无法播放此文件的格式或编码。可以分享或导出原文件，使用兼容的播放器打开。"
                }
            }
        } else if let url, imageExtensions.contains(url.pathExtension.lowercased()),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) {
            previewImage = UIImage(cgImage: image)
        }
    }
    private func readableText(_ url: URL) -> String? {
        guard ["txt", "json", "info"].contains(url.pathExtension.lowercased()),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

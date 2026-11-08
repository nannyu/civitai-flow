import SwiftUI
import FlowCore

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("muted") private var muted = true
    @AppStorage("blurMature") private var blurMature = true
    @State private var tokenDraft = ""
    @State private var credentialMessage: String?

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 18) {
                        FlowLogo(size: 72)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("flow").font(.system(.largeTitle, design: .rounded, weight: .semibold)).tracking(-1.2).foregroundStyle(FlowTheme.ink)
                            Text("Civitai 图片与视频").font(.subheadline).foregroundStyle(FlowTheme.muted)
                        }
                    }.padding(.vertical, 12).accessibilityElement(children: .combine).accessibilityLabel("Flow，Civitai 图片与视频")
                }.listRowBackground(FlowTheme.surface)
                Section("播放") {
                    Toggle("自动播放视频", isOn: $autoplay)
                    Toggle("默认静音", isOn: $muted)
                }.listRowBackground(FlowTheme.surface)
                Section {
                    ForEach(ContentRating.allCases, id: \.self) { rating in
                        Button {
                            state.ratings ^= rating.rawValue
                        } label: {
                            HStack {
                                Text(rating.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: state.ratings & rating.rawValue != 0 ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(state.ratings & rating.rawValue != 0 ? FlowTheme.accent : .secondary)
                            }.contentShape(Rectangle())
                        }.accessibilityLabel(rating.title).accessibilityValue(state.ratings & rating.rawValue != 0 ? "已选" : "未选")
                    }
                    Toggle("自动模糊 R+ 内容", isOn: $blurMature)
                } header: { Text("内容") } footer: {
                    Text(state.ratings == 0 ? "尚未选择等级，原生图片和视频列表将为空。" : "可同时选择多个等级，应用于原生作品与下载预览。R+ 包括 R、X、XXX，模糊后可轻点查看。官网页面使用其自身的等级设置。")
                }.listRowBackground(FlowTheme.surface)
                Section {
                    SecureField("粘贴 Civitai API Key（可选）", text: $tokenDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "移除 API Key" : "保存 API Key") {
                        do {
                            try state.saveToken(tokenDraft)
                            credentialMessage = state.token.isEmpty ? "已移除 API Key。" : "API Key 已安全保存。"
                        } catch { credentialMessage = error.localizedDescription }
                    }
                    if let credentialMessage { Text(credentialMessage).font(.caption).foregroundStyle(.secondary) }
                    if state.library.isSyncing { ProgressView("正在同步收藏夹…") }
                    if let account = state.library.account, !state.token.isEmpty { LabeledContent("同步账户", value: "@\(account.username)") }
                    if let error = state.library.syncError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if let date = state.library.lastSyncedAt { LabeledContent("上次同步") { Text(date, style: .relative).font(.caption) } }
                    Button("立即同步收藏夹") { Task { await state.syncLibrary() } }.disabled(state.token.isEmpty || state.library.isSyncing)
                    Link("前往 Civitai 账户设置", destination: URL(string: "https://civitai.red/user/account")!)
                } header: { Text("API 访问") } footer: {
                    Text("密钥仅保存在本机钥匙串。保存后自动同步 Civitai 收藏夹及图片、视频收藏；请使用具有收藏读写权限的 API Key。失败的本机修改会保留并可重试。")
                }.listRowBackground(FlowTheme.surface)
                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("收藏", value: state.token.isEmpty ? "本地存储" : "本地与 Civitai 同步")
                    Link("访问 Civitai", destination: URL(string: "https://civitai.red")!)
                    Text("独立开发的社区客户端，灵感来自 Civitai Flow。未使用其安装包代码或宣传图片，也不代表 Civitai 官方。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(FlowTheme.surface)
            }
            .flowListSurface()
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .onAppear { tokenDraft = state.token }
        }
    }
}

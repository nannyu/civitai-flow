import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("muted") private var muted = true
    @State private var tokenDraft = ""
    @State private var credentialMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.white)
                            .frame(width: 64, height: 64).background(FlowTheme.accent, in: RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Flow for iOS").font(.title3.bold())
                            Text("让灵感，自由流动。").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                Section("播放") {
                    Toggle("自动播放视频", isOn: $autoplay)
                    Toggle("默认静音", isOn: $muted)
                }
                Section {
                    Label("仅浏览普通内容（SFW）", systemImage: "leaf")
                } header: { Text("内容") } footer: {
                    Text("当前版本使用普通内容筛选，并检查返回作品的内容等级。")
                }
                Section {
                    SecureField("粘贴 Civitai API Key（可选）", text: $tokenDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "移除 API Key" : "保存 API Key") {
                        do {
                            try state.saveToken(tokenDraft)
                            credentialMessage = state.token.isEmpty ? "已移除 API Key。" : "API Key 已安全保存。"
                            Task { await state.feed.refresh(query: state.query, token: state.token) }
                        } catch { credentialMessage = error.localizedDescription }
                    }
                    if let credentialMessage { Text(credentialMessage).font(.caption).foregroundStyle(.secondary) }
                    Link("前往 Civitai 账户设置", destination: URL(string: "https://civitai.com/user/account")!)
                } header: { Text("API 访问") } footer: {
                    Text("浏览公开作品无需登录。密钥仅保存在本机钥匙串，用于访问 Civitai API；这不等同于网页登录，也不会同步账户收藏。")
                }
                Section("关于") {
                    LabeledContent("版本", value: "0.1.0")
                    LabeledContent("收藏", value: "本地存储")
                    Link("访问 Civitai", destination: URL(string: "https://civitai.com")!)
                    Text("独立开发的社区客户端，灵感来自 Civitai Flow。未使用其安装包代码或宣传图片，也不代表 Civitai 官方。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .onAppear { tokenDraft = state.token }
        }
    }
}

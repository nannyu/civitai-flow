import SwiftUI
import UIKit
import FlowCore

struct PromptSheet: View {
    let post: MediaPost
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var downloadResource: MediaPost.ModelResource?

    private let parameterKeys = ["Model", "model", "sampler", "steps", "cfgScale", "seed", "clipSkip", "Clip skip", "Size"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("创作者", value: post.creator)
                    if let model = post.baseModel { LabeledContent("基础模型", value: model) }
                    if let width = post.width, let height = post.height { LabeledContent("尺寸", value: "\(width) × \(height)") }
                }
                if let prompt = post.prompt {
                    Section("正向提示词") {
                        Text(prompt).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = prompt
                            copied = true
                        } label: { Label(copied ? "已复制提示词" : "复制提示词", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    }
                } else {
                    Section { Label("作者未公开提示词", systemImage: "text.badge.xmark").foregroundStyle(.secondary) }
                }
                if let negative = post.negativePrompt {
                    Section("反向提示词") {
                        Text(negative).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                        Button("复制反向提示词") { UIPasteboard.general.string = negative }
                    }
                }
                if parameterKeys.contains(where: { post.nonemptyMetadata($0) != nil }) {
                    Section("生成参数") {
                        ForEach(parameterKeys, id: \.self) { key in
                            if let value = post.nonemptyMetadata(key) { LabeledContent(key, value: value).textSelection(.enabled) }
                        }
                    }
                }
                if let resources = post.nonemptyMetadata("resources") ?? post.nonemptyMetadata("civitaiResources") {
                    Section("模型与 LoRA") {
                        Text(resources).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if !post.modelResources.isEmpty {
                    Section("下载模型与 LoRA") {
                        ForEach(post.modelResources) { resource in
                            Button { downloadResource = resource } label: {
                                Label(resource.name, systemImage: "arrow.down.circle")
                            }
                        }
                    }
                }
                Section {
                    Link(destination: post.webURL) { Label("在 Civitai 查看完整作品", systemImage: "arrow.up.right.square") }
                } footer: { Text("仅显示作者公开的生成信息；部分作品不包含提示词或模型参数。") }
            }
            .navigationTitle("灵感配方").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .sheet(item: $downloadResource) { ModelDownloadSheet(initialLink: $0.downloadURL.absoluteString) }
    }
}

import AppKit
import SwiftUI

struct PopoverRootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if state.showingSettings {
                SettingsView(state: state)
            } else {
                UploadView(state: state)
            }
        }
        .frame(width: 390, height: 560)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 20, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text("CALIPH DROP")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text("Drag · Compress · Upload")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.showingSettings.toggle()
            } label: {
                Image(systemName: state.showingSettings ? "xmark" : "gearshape")
            }
            .buttonStyle(.plain)
            .help(state.showingSettings ? "返回" : "设置")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct UploadView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("把图片拖到屏幕顶部的 Caliph 图标")
                    .font(.system(size: 13, weight: .semibold))
                Text("也可以从这里选择；支持一次多张")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("选择图片上传") { state.chooseImages() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            )

            if state.items.isEmpty {
                Spacer()
                VStack(spacing: 5) {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundStyle(.secondary)
                    Text("日常只需要一个动作：拖上去")
                        .font(.system(size: 12, weight: .medium))
                    Text("图片会先在本机压缩，再发送到你的上传 API")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(state.items) { item in
                            UploadRow(item: item)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Text(state.message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if state.items.contains(where: { if case .failed = $0.status { return true }; return false }) {
                    Button("重试") { state.retryFailed() }
                        .controlSize(.mini)
                }
                if !state.items.isEmpty {
                    Button("清理") { state.clearFinished() }
                        .controlSize(.mini)
                }
            }
        }
        .padding(14)
    }
}

private struct UploadRow: View {
    let item: UploadItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.sourceURL.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(item.status.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(.secondary.opacity(0.07)))
    }

    private var icon: String {
        switch item.status {
        case .waiting: return "clock"
        case .processing: return "wand.and.stars"
        case .uploading: return "arrow.up.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var detail: String {
        switch item.status {
        case .waiting: return "等待处理"
        case .processing: return "正在缩小尺寸并重新编码"
        case .uploading: return "正在发送到网站"
        case let .done(url): return url ?? "上传成功"
        case let .failed(reason): return reason
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                sectionTitle("Caliph 上传")
                field("上传地址", text: $state.uploadURL, placeholder: "https://caliph.chengyu.dev/api/drop")
                secureField("CALIPH_DROP_TOKEN", text: $state.token, placeholder: "只保存在 macOS Keychain")

                Toggle("上传后立即发布到图库", isOn: $state.publishImmediately)
                Toggle("使用文件名作为标题", isOn: $state.useFilenameAsTitle)
                Toggle("成功后复制最后一张图片 URL", isOn: $state.copyLastURL)

                sectionTitle("沿用网站现有压缩规则")
                HStack {
                    Text("最长边")
                    Spacer()
                    Text("\(Int(state.maxPixel)) px").foregroundStyle(.secondary)
                }
                Slider(value: $state.maxPixel, in: 1280...4096, step: 128)

                HStack {
                    Text("质量")
                    Spacer()
                    Text(String(format: "%.0f%%", state.quality * 100)).foregroundStyle(.secondary)
                }
                Slider(value: $state.quality, in: 0.6...0.95, step: 0.01)

                Toggle("优先输出 WebP（系统编码器支持时）", isOn: $state.preferWebP)

                Text("默认参数已经与你的网站后台一致：最长边 2560px、质量 0.88；如果压缩后没有变小，会自动保留原图。Token 不会写进源码，而是保存在 macOS Keychain。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("退出 Caliph Drop") { state.quit() }
                        .controlSize(.small)
                    Spacer()
                    Button("保存") { state.saveSettings() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .tracking(0.8)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity)
    }

    private func secureField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium))
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }
}

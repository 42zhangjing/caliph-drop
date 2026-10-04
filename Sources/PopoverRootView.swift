import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum DropStyle {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.55)
    static let accent = Color(nsColor: .systemBlue)
}

struct PopoverRootView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CALIPH DROP").font(.system(size: 14, weight: .bold, design: .rounded)).tracking(0.7)
                    Text(state.showingSettings ? "设置" : "图片上传 · 本机压缩")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("0.5").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button {
                    if state.showingSettings { state.closeSettings() } else { state.openSettings() }
                } label: {
                    Image(systemName: state.showingSettings ? "arrow.left" : "gearshape")
                        .font(.system(size: 14)).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.showingSettings ? "返回，保留未保存的设置" : "设置")
                .accessibilityLabel(state.showingSettings ? "返回上传" : "打开设置")
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            if state.showingSettings { SettingsView(state: state) }
            else if let pending = state.pendingImports.first { ImportReview(state: state, pending: pending) }
            else { UploadView(state: state) }
        }
        .frame(width: 416, height: 570)
        .background(DropStyle.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DropStyle.border, lineWidth: 1))
        .tint(DropStyle.accent)
    }
}

private struct UploadView: View {
    @ObservedObject var state: AppState
    @State private var targeted = false
    private var batch: [UploadItem] { state.currentBatch }
    private var finished: Int { batch.filter { $0.status.isFinished }.count }
    private var failed: Int { batch.filter { $0.status.canRetry }.count }
    private var displayed: [UploadItem] {
        state.items.filter { $0.batchId == state.latestBatchId } + state.items.filter { $0.batchId != state.latestBatchId }
    }
    var body: some View {
        VStack(spacing: 12) {
            dropZone
            if state.items.isEmpty {
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Text("把图片放进来，剩下的交给 Drop")
                        .font(.system(size: 13, weight: .medium))
                    Text("支持 Finder 文件与粘贴图片\n多张图片可分别收录，也可合并为图集")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineSpacing(4)
                }
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Text("本批次 \(finished) / \(batch.count) 已处理").font(.system(size: 12, weight: .medium))
                        if failed > 0 { Text("\(failed) 项需处理").font(.system(size: 11)).foregroundStyle(.orange) }
                        Spacer()
                        if state.items.contains(where: { !$0.status.isFinished }) {
                            Button(state.isPaused ? "继续" : "暂停") { state.togglePause() }.controlSize(.small)
                        }
                    }
                    ProgressView(value: Double(finished), total: Double(max(1, batch.count)))
                        .controlSize(.small).accessibilityLabel("当前批次处理进度")
                    if state.isPaused {
                        Text("队列已暂停；正在发送的任务会先完成")
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(displayed) { item in UploadRow(state: state, item: item) }
                    }.padding(.vertical, 1)
                }
            }
            Spacer(minLength: 0).frame(height: 0)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(state.message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .help(state.message)
                if !state.items.isEmpty {
                    HStack(spacing: 10) {
                        if state.items.contains(where: { $0.isRetryable && $0.status.canRetry }) {
                            Button("重试未完成") { state.retryFailed() }.controlSize(.small)
                        }
                        Spacer()
                        Button("清理成功项") { state.clearFinished() }.controlSize(.small)
                            .help("保留失败与未完成任务")
                    }
                }
            }
        }.padding(16)
    }
    private var dropZone: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: targeted ? "arrow.down.doc" : "photo.on.rectangle.angled")
                    .font(.system(size: state.items.isEmpty ? 30 : 23, weight: .light))
                    .foregroundStyle(targeted ? DropStyle.accent : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(targeted ? "松开导入图片" : "拖入图片")
                        .font(.system(size: 15, weight: .semibold))
                    Text("也可直接粘贴 ⌘V").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择图片") { state.chooseImages() }.controlSize(.regular)
            }
            if state.items.isEmpty {
                HStack {
                    Text("JPG · PNG · HEIC · WebP · AVIF · TIFF")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button("粘贴图片") { state.pasteImages() }.buttonStyle(.link).font(.system(size: 12))
                }.padding(.top, 12)
            }
        }
        .padding(16).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 11).fill(targeted ? DropStyle.accent.opacity(0.08) : DropStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(targeted ? DropStyle.accent : DropStyle.border,
            style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: targeted ? [] : [4, 4])))
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL.identifier, UTType.png.identifier, UTType.tiff.identifier], isTargeted: $targeted) {
            ImageImport.load($0, into: state)
        }
    }
}

private struct UploadRow: View {
    @ObservedObject var state: AppState
    let item: UploadItem
    @State private var expanded = false
    private var color: Color {
        switch item.status {
        case .done: return item.result?.publicationStatus == "published" ? .green : .secondary
        case .failed, .uncertain, .blocked: return .orange
        case .processing, .uploading: return DropStyle.accent
        default: return .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                ImageThumbnail(url: item.sourceURL).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.sourceURL.lastPathComponent).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle).help(item.sourceURL.lastPathComponent)
                    HStack(spacing: 5) {
                        if item.status.isActive { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
                        Text(item.resultLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                        if item.groupId != nil {
                            Text(item.isGroupLeader ? "· 主图" : "· 附图").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Text(item.processed?.sizeSummary ?? item.timeLabel)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    if item.result?.url != nil {
                        Button("复制图片链接") { state.copyURL(item) }
                        Button("打开图片") { state.openResult(item) }
                    }
                    if item.isRetryable && item.status.canRetry { Button("重试任务") { state.retryItem(item.id) } }
                    if !item.status.isActive, !(item.status == .cancelled) {
                        if case .done = item.status {} else { Button("取消任务") { state.cancelItem(item.id) } }
                    }
                    Button(expanded ? "收起详情" : "查看详情") { expanded.toggle() }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).frame(width: 28)
                .accessibilityLabel("\(item.sourceURL.lastPathComponent)的操作")
            }
            if let error = item.status.error {
                Button { expanded.toggle() } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                        Text(error).lineLimit(expanded ? nil : 2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }.font(.system(size: 11)).foregroundStyle(.orange)
                }.buttonStyle(.plain)
            }
            if expanded {
                Text(item.timeLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                if let value = item.result?.url { Text(value).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if item.result?.needsReview == true {
                    Text("图片已保存为草稿，请到网站管理端补充标题后发布。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DropStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DropStyle.border.opacity(0.65), lineWidth: 0.5))
    }
}

private struct ImportReview: View {
    @ObservedObject var state: AppState
    let pending: PendingImport
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("准备上传 \(pending.urls.count) 张图片").font(.system(size: 16, weight: .semibold))
                    Text(state.pendingImports.count > 1 ? "另有 \(state.pendingImports.count - 1) 批图片等待确认" : "检查图片与顺序，再选择收录方式")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(Array(pending.urls.enumerated()), id: \.element) { index, url in
                        HStack(spacing: 10) {
                            ImageThumbnail(url: url).frame(width: 46, height: 42)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Text(pending.grouped && index == 0 ? "合辑主图" : "第 \(index + 1) 张").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button { state.movePending(url, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 24, height: 28) }
                                .disabled(index == 0).help("向前移动").accessibilityLabel("向前移动图片")
                            Button { state.movePending(url, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 24, height: 28) }
                                .disabled(index == pending.urls.count - 1).help("向后移动").accessibilityLabel("向后移动图片")
                            Button { state.removePending(url) } label: { Image(systemName: "minus.circle").frame(width: 24, height: 28) }
                                .help("从本批次移除").accessibilityLabel("移除图片")
                        }.buttonStyle(.plain).padding(8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(DropStyle.surface))
                    }
                }
            }
            Picker("收录方式", selection: Binding(get: { state.pendingGrouped }, set: { state.pendingGrouped = $0 })) {
                Text("分别收录").tag(false)
                Text("合并为图集").tag(true)
            }.pickerStyle(.segmented)
            if pending.grouped {
                VStack(alignment: .leading, spacing: 6) {
                    Text("图集标题").font(.system(size: 12, weight: .medium))
                    TextField("可留空，由网站补充", text: Binding(get: { state.pendingGroupTitle }, set: { state.pendingGroupTitle = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                    Text("第一张为主图，后续图片按上方顺序加入。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("每张图片分别创建一条图库记录。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("取消这批") { state.cancelMultiDrop() }
                Spacer()
                Button(pending.grouped ? "上传图集" : "上传 \(pending.urls.count) 张") { state.confirmPending() }
                    .buttonStyle(.borderedProminent)
            }.controlSize(.regular)
        }.padding(16)
    }
}

private struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var advanced = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    section("上传连接") {
                        field("上传地址") {
                            TextField("https://caliph.chengyu.dev/api/drop", text: $state.uploadURL).textFieldStyle(.roundedBorder)
                        }
                        field("上传密钥") { SecureField("保存在 macOS 钥匙串", text: $state.token).textFieldStyle(.roundedBorder) }
                    }
                    section("上传之后") {
                        Toggle("自动发布到图库", isOn: $state.publishImmediately)
                        Text("网站需要补充标题时会保留为草稿，并在结果中标明。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Toggle("使用文件名作为标题", isOn: $state.useFilenameAsTitle)
                        Toggle("复制最后一张图片链接", isOn: $state.copyLastURL)
                    }
                    section("启动") {
                        Toggle("登录时自动启动", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                        Text("此开关立即生效").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("高级压缩设置", isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text("最长边"); Spacer(); Text("\(Int(state.maxPixel)) px").monospacedDigit() }
                            Slider(value: $state.maxPixel, in: 1280...4096, step: 128).accessibilityLabel("最长边像素")
                            HStack { Text("质量"); Spacer(); Text("\(Int(state.quality * 100))%").monospacedDigit() }
                            Slider(value: $state.quality, in: 0.6...0.95, step: 0.01).accessibilityLabel("图片压缩质量")
                            Toggle("优先 WebP", isOn: $state.preferWebP)
                            Text("默认 2560 px / 88%。系统不支持 WebP 时保留透明度并回退 PNG 或 JPEG。仅对新导入的任务生效。")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(.top, 10)
                    }.font(.system(size: 12, weight: .medium))
                }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.small).padding(18)
            }
            if !state.settingsMessage.isEmpty {
                Text(state.settingsMessage).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 10)
                    .accessibilityLabel("设置提示：\(state.settingsMessage)")
            }
            Divider()
            HStack {
                Menu("更多") { Button("退出 Caliph Drop") { state.quit() } }.frame(width: 65)
                Spacer()
                Button("放弃修改") { state.cancelSettings() }
                Button("保存设置") { state.saveSettings() }.buttonStyle(.borderedProminent)
            }.controlSize(.regular).padding(16)
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12)); content().font(.system(size: 13)) }
    }
}

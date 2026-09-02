import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PopoverRootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if state.showingSettings {
                SettingsView(state: state)
            } else if let urls = state.pendingMultiDropURLs, !urls.isEmpty {
                MultiDropConfirmView(state: state, urls: urls)
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
                if state.showingSettings {
                    state.closeSettings()
                } else if state.pendingMultiDropURLs != nil {
                    state.cancelMultiDrop()
                } else {
                    state.openSettings()
                }
            } label: {
                Image(systemName: state.showingSettings || state.pendingMultiDropURLs != nil ? "xmark" : "gearshape")
            }
            .buttonStyle(.plain)
            .help(state.showingSettings ? "返回" : (state.pendingMultiDropURLs != nil ? "取消多图导入" : "设置"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct MultiDropConfirmView: View {
    @ObservedObject var state: AppState
    let urls: [URL]
    @State private var selectedMode: MultiDropMode = .separate

    enum MultiDropMode {
        case separate
        case group
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("检测到 \(urls.count) 张图片")
                        .font(.system(size: 14, weight: .bold))
                    Text("请选择多张图片的收录方式")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") {
                    state.cancelMultiDrop()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 4)

            // 预览列表
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(urls, id: \.self) { url in
                        VStack(spacing: 4) {
                            if let nsImage = NSImage(contentsOf: url) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 58, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.15))
                                    .frame(width: 58, height: 58)
                                    .overlay(
                                        Image(systemName: "photo")
                                            .foregroundStyle(.secondary)
                                    )
                            }
                            Text(url.lastPathComponent)
                                .font(.system(size: 9))
                                .lineLimit(1)
                                .frame(width: 62)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 84)

            Divider()

            VStack(spacing: 10) {
                // 选项 A：分别收录
                Button {
                    selectedMode = .separate
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selectedMode == .separate ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedMode == .separate ? Color.accentColor : Color.secondary)
                            .font(.system(size: 14))
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("分别独立收录（推荐）")
                                .font(.system(size: 12, weight: .semibold))
                            Text("每张图片各创建一条独立的图库记录")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selectedMode == .separate ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selectedMode == .separate ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // 选项 B：合并为一条
                Button {
                    selectedMode = .group
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selectedMode == .group ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedMode == .group ? Color.accentColor : Color.secondary)
                            .font(.system(size: 14))
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("合并为一条记录（图集合辑）")
                                .font(.system(size: 12, weight: .semibold))
                            Text("所有图片归入同一条图库记录的媒体列表中")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selectedMode == .group ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selectedMode == .group ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                if selectedMode == .group {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("合辑标题（选填）")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("默认为第一张图片文件名", text: $state.pendingGroupTitle)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Spacer()

            HStack {
                Button("取消") {
                    state.cancelMultiDrop()
                }
                .controlSize(.regular)
                Spacer()
                Button(selectedMode == .separate ? "分别收录并上传 (\(urls.count)张)" : "合并收录并上传 (\(urls.count)张)") {
                    if selectedMode == .separate {
                        state.confirmMultiDropSeparate()
                    } else {
                        state.confirmMultiDropGroup(title: state.pendingGroupTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.15), value: selectedMode)
    }
}

private struct UploadView: View {
    @ObservedObject var state: AppState
    @State private var isDropTargeted = false

    private var completedCount: Int {
        state.items.reduce(into: 0) { count, item in
            if case .done = item.status {
                count += 1
            }
        }
    }

    private var failedCount: Int {
        state.items.reduce(into: 0) { count, item in
            if case .failed = item.status {
                count += 1
            }
        }
    }

    private var progressValue: Double {
        guard !state.items.isEmpty else { return 0 }
        return Double(completedCount) / Double(state.items.count)
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 10) {
                Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "photo.stack")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                Text(isDropTargeted ? "松开即可上传" : "把图片拖到这里或顶部 Caliph 图标")
                    .font(.system(size: 13, weight: .semibold))
                Text("支持单张或多张拖入；也可点击下方按钮选择")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("选择图片上传") { state.chooseImages() }
                    .controlSize(.regular)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: state.items.isEmpty ? 200 : 175)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.primary.opacity(0.28),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2.0 : 1.2, dash: [6, 6])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }

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
                VStack(spacing: 7) {
                    HStack(spacing: 8) {
                        Text("\(completedCount) / \(state.items.count) 完成")
                            .font(.system(size: 10, weight: .semibold))
                        if failedCount > 0 {
                            Text("· \(failedCount) 失败")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .animation(.easeOut(duration: 0.18), value: progressValue)
                }
                .padding(.horizontal, 2)

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
                if state.items.contains(where: {
                    guard $0.isRetryable else { return false }
                    if case .failed = $0.status { return true }
                    return false
                }) {
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

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: NSURL.self) }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var loaded = Array<URL?>(repeating: nil, count: fileProviders.count)
        var failedNames = Array<String?>(repeating: nil, count: fileProviders.count)

        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadObject(ofClass: NSURL.self) { object, error in
                lock.lock()
                if let url = object as? URL, error == nil {
                    loaded[index] = url
                } else {
                    failedNames[index] = provider.suggestedName ?? "无法读取的文件 \(index + 1)"
                }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            state.enqueue(urls: loaded.compactMap { $0 })
            state.addDropFailures(failedNames.compactMap { $0 })
        }
        return true
    }
}

private struct UploadRow: View {
    let item: UploadItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.sourceURL.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if let _ = item.groupId {
                        Text(item.isGroupLeader ? "合辑主图" : "合辑附图")
                            .font(.system(size: 8, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.status.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(item.formattedTime)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.75))
            }
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

    private var iconColor: Color {
        switch item.status {
        case .waiting: return .secondary
        case .processing, .uploading: return .accentColor
        case .done: return .green
        case .failed: return .red
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .waiting: return .secondary
        case .processing, .uploading: return .accentColor
        case .done: return .green
        case .failed: return .red
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
                Toggle(
                    "登录时自动启动",
                    isOn: Binding(
                        get: { state.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    )
                )

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

                Text("默认参数已经与你的网站后台一致：最长边 2560px、质量 0.88。只有无需缩放、没有相机/GPS 等私密元数据且重新编码没有更小时，才会保留原图。Token 不会写进源码，而是保存在 macOS Keychain。")
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
        .onAppear { state.refreshLaunchAtLoginStatus() }
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

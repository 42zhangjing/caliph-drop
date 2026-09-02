import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

private struct UploadConfiguration: Sendable {
    var uploadURL: String
    var token: String
    var maxPixel: Double
    var quality: Double
    var preferWebP: Bool
    var publishImmediately: Bool
    var useFilenameAsTitle: Bool
    var copyLastURL: Bool
}

@MainActor
final class AppState: ObservableObject {
    @Published var uploadURL: String = "https://caliph.chengyu.dev/api/drop"
    @Published var token: String = ""
    @Published var maxPixel: Double = 2560
    @Published var quality: Double = 0.88
    @Published var preferWebP: Bool = true
    @Published var publishImmediately: Bool = true
    @Published var useFilenameAsTitle: Bool = false
    @Published var copyLastURL: Bool = true
    @Published private(set) var launchAtLogin: Bool = false
    @Published var items: [UploadItem] = []
    @Published var message: String = "把图片拖到顶部菜单栏的上传图标即可"
    @Published var showingSettings: Bool = false
    @Published var pendingMultiDropURLs: [URL]? = nil
    @Published var pendingGroupTitle: String = ""

    private let defaults = UserDefaults.standard
    private let tokenAccount = "caliph-drop-upload-token"
    private var uploadTask: Task<Void, Never>?
    private var groupCollectionMap: [UUID: String] = [:]
    private var savedSettings = UploadConfiguration(
        uploadURL: "https://caliph.chengyu.dev/api/drop",
        token: "",
        maxPixel: 2560,
        quality: 0.88,
        preferWebP: true,
        publishImmediately: true,
        useFilenameAsTitle: false,
        copyLastURL: true
    )

    func loadSettings() {
        uploadURL = defaults.string(forKey: "uploadURL") ?? "https://caliph.chengyu.dev/api/drop"
        maxPixel = defaults.object(forKey: "maxPixel") as? Double ?? 2560
        quality = defaults.object(forKey: "quality") as? Double ?? 0.88
        preferWebP = defaults.object(forKey: "preferWebP") as? Bool ?? true
        publishImmediately = defaults.object(forKey: "publishImmediately") as? Bool ?? true
        useFilenameAsTitle = defaults.object(forKey: "useFilenameAsTitle") as? Bool ?? false
        copyLastURL = defaults.object(forKey: "copyLastURL") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        do {
            token = try KeychainStore.load(account: tokenAccount) ?? ""
        } catch {
            token = ""
            message = "无法读取 Keychain：\(error.localizedDescription)"
        }
        savedSettings = draftConfiguration(token: token)
        showingSettings = token.isEmpty
    }

    func saveSettings() {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            message = "请先填入 CALIPH_DROP_TOKEN"
            showingSettings = true
            return
        }
        guard let endpoint = UploadEndpoint.url(from: uploadURL) else {
            message = "上传地址必须是 HTTPS；本机调试仅允许 localhost HTTP"
            showingSettings = true
            return
        }

        do {
            try KeychainStore.save(normalizedToken, account: tokenAccount)
        } catch {
            message = "Token 保存失败：\(error.localizedDescription)"
            showingSettings = true
            return
        }

        token = normalizedToken
        uploadURL = endpoint.absoluteString
        savedSettings = draftConfiguration(token: normalizedToken)
        defaults.set(savedSettings.uploadURL, forKey: "uploadURL")
        defaults.set(maxPixel, forKey: "maxPixel")
        defaults.set(quality, forKey: "quality")
        defaults.set(preferWebP, forKey: "preferWebP")
        defaults.set(publishImmediately, forKey: "publishImmediately")
        defaults.set(useFilenameAsTitle, forKey: "useFilenameAsTitle")
        defaults.set(copyLastURL, forKey: "copyLastURL")
        message = "设置已保存"
        showingSettings = false
        startQueueIfNeeded()
    }

    func openSettings() {
        restoreDraftFromSavedSettings()
        refreshLaunchAtLoginStatus()
        showingSettings = true
    }

    func closeSettings() {
        restoreDraftFromSavedSettings()
        showingSettings = false
        if savedSettings.token.isEmpty, items.contains(where: { $0.status == .waiting }) {
            message = "队列正在等待 Token；可重新打开设置，或点“清理”取消"
        }
    }

    func discardUnsavedSettings() {
        guard showingSettings else { return }
        restoreDraftFromSavedSettings()
        if savedSettings.token.isEmpty, items.contains(where: { $0.status == .waiting }) {
            message = "队列正在等待 Token；请保存设置后继续"
        }
    }

    func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SupportedImage.contentTypes
        panel.begin { [weak self] result in
            guard result == .OK else { return }
            Task { @MainActor in
                self?.enqueue(urls: panel.urls)
            }
        }
    }

    func enqueue(urls: [URL]) {
        let filtered = SupportedImage.filter(urls)
        guard !filtered.isEmpty else {
            message = "没有识别到可上传的图片"
            return
        }

        guard !savedSettings.token.isEmpty else {
            if filtered.count > 1 {
                pendingMultiDropURLs = filtered
            } else {
                items.append(contentsOf: filtered.map { UploadItem(sourceURL: $0) })
            }
            openSettings()
            message = "第一次使用：先填入 CALIPH_DROP_TOKEN"
            return
        }

        if filtered.count > 1 {
            pendingMultiDropURLs = filtered
            pendingGroupTitle = filtered.first?.deletingPathExtension().lastPathComponent ?? ""
            showingSettings = false
            return
        }

        items.append(UploadItem(sourceURL: filtered[0]))
        startQueueIfNeeded()
    }

    func confirmMultiDropSeparate() {
        guard let urls = pendingMultiDropURLs, !urls.isEmpty else { return }
        pendingMultiDropURLs = nil
        items.append(contentsOf: urls.map { UploadItem(sourceURL: $0) })
        startQueueIfNeeded()
    }

    func confirmMultiDropGroup(title: String) {
        guard let urls = pendingMultiDropURLs, !urls.isEmpty else { return }
        pendingMultiDropURLs = nil
        let groupId = UUID()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var groupItems: [UploadItem] = []
        for (index, url) in urls.enumerated() {
            let isLeader = (index == 0)
            let itemTitle = isLeader ? (cleanTitle.isEmpty ? nil : cleanTitle) : nil
            groupItems.append(
                UploadItem(
                    sourceURL: url,
                    customTitle: itemTitle,
                    groupId: groupId,
                    isGroupLeader: isLeader
                )
            )
        }
        items.append(contentsOf: groupItems)
        startQueueIfNeeded()
    }

    func cancelMultiDrop() {
        pendingMultiDropURLs = nil
        pendingGroupTitle = ""
    }

    func addDropFailures(_ names: [String]) {
        guard !names.isEmpty else { return }
        for name in names {
            items.append(UploadItem(failedFileName: name, reason: "无法从 Finder 读取该文件"))
        }
        message = "有 \(names.count) 个文件无法读取，已在队列中标记失败"
    }

    func retryFailed() {
        for index in items.indices {
            if case .failed = items[index].status, items[index].isRetryable {
                items[index].status = .waiting
            }
        }
        startQueueIfNeeded()
    }

    func clearFinished() {
        items.removeAll {
            switch $0.status {
            case .done, .failed: return true
            case .waiting: return savedSettings.token.isEmpty
            case .processing, .uploading: return false
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            switch SMAppService.mainApp.status {
            case .enabled:
                launchAtLogin = true
                message = "已启用登录时自动启动"
            case .requiresApproval:
                launchAtLogin = false
                message = "请在系统设置 → 通用 → 登录项中允许 Caliph Drop"
            case .notFound:
                launchAtLogin = false
                message = "请先把 Caliph Drop 放入“应用程序”文件夹再开启"
            case .notRegistered:
                launchAtLogin = false
                message = "已关闭登录时自动启动"
            @unknown default:
                launchAtLogin = false
                message = "登录启动项状态未知，请在系统设置中确认"
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = "无法修改登录启动项：\(error.localizedDescription)"
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func startQueueIfNeeded() {
        guard uploadTask == nil else { return }
        uploadTask = Task { [weak self] in
            guard let self else { return }
            await self.processQueue()
            self.uploadTask = nil
        }
    }

    private func processQueue() async {
        while let index = items.firstIndex(where: { $0.status == .waiting }) {
            let item = items[index]
            let id = item.id
            let sourceURL = item.sourceURL
            let groupId = item.groupId
            let isGroupLeader = item.isGroupLeader
            let customTitle = item.customTitle
            let settings = savedSettings
            items[index].status = .processing
            message = "正在处理 \(sourceURL.lastPathComponent)…"

            do {
                let processed = try await Task.detached(priority: .userInitiated) {
                    try ImageProcessor.process(
                        sourceURL: sourceURL,
                        maxPixel: Int(settings.maxPixel),
                        quality: settings.quality,
                        preferWebP: settings.preferWebP
                    )
                }.value
                defer { try? FileManager.default.removeItem(at: processed.fileURL) }

                guard let currentIndex = items.firstIndex(where: { $0.id == id }) else { continue }
                items[currentIndex].status = .uploading
                message = "正在上传 \(processed.fileName)…"

                var targetCollectionId: String? = nil
                if let groupId = groupId, !isGroupLeader {
                    targetCollectionId = groupCollectionMap[groupId]
                }

                let title: String
                if let customTitle = customTitle, !customTitle.isEmpty {
                    title = customTitle
                } else if settings.useFilenameAsTitle {
                    title = sourceURL.deletingPathExtension().lastPathComponent
                } else {
                    title = ""
                }

                let result = try await Uploader.upload(
                    image: processed,
                    endpoint: settings.uploadURL,
                    token: settings.token,
                    title: title,
                    publish: settings.publishImmediately,
                    collectionId: targetCollectionId
                )

                if let groupId = groupId, isGroupLeader, let returnedId = result.collectionId {
                    groupCollectionMap[groupId] = returnedId
                }

                guard let finishedIndex = items.firstIndex(where: { $0.id == id }) else { continue }
                items[finishedIndex].status = .done(result.url)

                let before = ByteCountFormatter.string(fromByteCount: processed.originalBytes, countStyle: .file)
                let after = ByteCountFormatter.string(fromByteCount: processed.outputBytes, countStyle: .file)
                message = "✓ \(sourceURL.lastPathComponent)：\(before) → \(after)"

                if settings.copyLastURL, let url = result.url, !url.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            } catch {
                if let failedIndex = items.firstIndex(where: { $0.id == id }) {
                    items[failedIndex].status = .failed(error.localizedDescription)
                }
                message = "上传失败：\(error.localizedDescription)"
            }
        }
    }

    private func draftConfiguration(token normalizedToken: String) -> UploadConfiguration {
        UploadConfiguration(
            uploadURL: uploadURL,
            token: normalizedToken,
            maxPixel: maxPixel,
            quality: quality,
            preferWebP: preferWebP,
            publishImmediately: publishImmediately,
            useFilenameAsTitle: useFilenameAsTitle,
            copyLastURL: copyLastURL
        )
    }

    private func restoreDraftFromSavedSettings() {
        uploadURL = savedSettings.uploadURL
        token = savedSettings.token
        maxPixel = savedSettings.maxPixel
        quality = savedSettings.quality
        preferWebP = savedSettings.preferWebP
        publishImmediately = savedSettings.publishImmediately
        useFilenameAsTitle = savedSettings.useFilenameAsTitle
        copyLastURL = savedSettings.copyLastURL
    }
}

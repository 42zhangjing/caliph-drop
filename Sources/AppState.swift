import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    typealias UploadHandler = (ProcessedImage, UploadOptions, String, String?, UUID) async throws -> UploadResult
    @Published var uploadURL = "https://caliph.chengyu.dev/api/drop"
    @Published var token = ""
    @Published var maxPixel = 2560.0
    @Published var quality = 0.88
    @Published var preferWebP = true
    @Published var publishImmediately = true
    @Published var useFilenameAsTitle = false
    @Published var copyLastURL = true
    @Published private(set) var launchAtLogin = false
    @Published var items: [UploadItem] = [] { didSet { persistQueue() } }
    @Published var pendingImports: [PendingImport] = [] { didSet { persistQueue() } }
    @Published var message = "拖入图片，或选择文件开始上传"
    @Published var settingsMessage = ""
    @Published var showingSettings = false
    @Published var isChoosingImages = false
    @Published var isPaused = false
    @Published var isShowingQuitConfirmation = false
    @Published var latestBatchId: UUID?
    weak var hostWindow: NSWindow?
    var presentPanel: (() -> Void)?
    var didApproveQuit: (() -> Void)?
    private let defaults: UserDefaults
    let storageURL: URL
    private let upload: UploadHandler
    private let readToken: () throws -> String?
    private let writeToken: (String) throws -> Void
    private var savedOptions = UploadOptions()
    private var savedToken = ""
    private var uploadTask: Task<Void, Never>?
    private var hasSettingsDraft = false
    private var restoredQueue = false
    private var persistenceEnabled: Bool

    init(defaults: UserDefaults = .standard, storageURL: URL? = nil,
         persistenceEnabled: Bool = true,
         readToken: @escaping () throws -> String? = { try KeychainStore.load(account: "caliph-drop-upload-token") },
         writeToken: @escaping (String) throws -> Void = { try KeychainStore.save($0, account: "caliph-drop-upload-token") },
         upload: @escaping UploadHandler = { image, options, token, collectionId, id in
             try await Uploader.upload(image: image, endpoint: options.endpoint, token: token,
                 title: options.title, publish: options.publish, collectionId: collectionId, uploadId: id)
         }) {
        self.defaults = defaults
        self.storageURL = storageURL ?? Self.defaultStorageURL
        self.persistenceEnabled = persistenceEnabled
        self.readToken = readToken; self.writeToken = writeToken
        self.upload = upload
    }
    static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Caliph Drop", isDirectory: true)
    }
    var hasUnfinished: Bool { items.contains { !$0.status.isFinished || $0.status.canRetry } || !pendingImports.isEmpty }
    var isWorking: Bool { items.contains { $0.status.isActive } }
    var canDismiss: Bool { !isChoosingImages && !isShowingQuitConfirmation }
    var currentBatch: [UploadItem] {
        guard let latestBatchId else { return items }
        return items.filter { $0.batchId == latestBatchId }
    }
    var pendingGroupTitle: String {
        get { pendingImports.first?.title ?? "" }
        set { if !pendingImports.isEmpty { pendingImports[0].title = newValue } }
    }
    var pendingGrouped: Bool {
        get { pendingImports.first?.grouped ?? false }
        set { if !pendingImports.isEmpty { pendingImports[0].grouped = newValue } }
    }

    func loadSettings() {
        uploadURL = defaults.string(forKey: "uploadURL") ?? uploadURL
        maxPixel = defaults.object(forKey: "maxPixel") as? Double ?? maxPixel
        quality = defaults.object(forKey: "quality") as? Double ?? quality
        preferWebP = defaults.object(forKey: "preferWebP") as? Bool ?? preferWebP
        publishImmediately = defaults.object(forKey: "publishImmediately") as? Bool ?? publishImmediately
        useFilenameAsTitle = defaults.object(forKey: "useFilenameAsTitle") as? Bool ?? useFilenameAsTitle
        copyLastURL = defaults.object(forKey: "copyLastURL") as? Bool ?? copyLastURL
        do { token = try readToken() ?? "" }
        catch { settingsMessage = "无法读取上传密钥：\(error.localizedDescription)" }
        savedOptions = draftOptions(); savedToken = token
        refreshLaunchAtLoginStatus()
        showingSettings = token.isEmpty
        restoreQueue()
    }
    func saveSettings() {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { settingsMessage = "请填写上传密钥"; return }
        guard let endpoint = UploadEndpoint.url(from: uploadURL) else {
            settingsMessage = "请填写有效 HTTPS 上传地址；本机调试可使用 localhost HTTP"; return
        }
        do { try writeToken(normalized) }
        catch { settingsMessage = "密钥保存失败：\(error.localizedDescription)"; return }
        token = normalized; uploadURL = endpoint.absoluteString
        savedToken = normalized; savedOptions = draftOptions()
        defaults.set(uploadURL, forKey: "uploadURL"); defaults.set(maxPixel, forKey: "maxPixel")
        defaults.set(quality, forKey: "quality"); defaults.set(preferWebP, forKey: "preferWebP")
        defaults.set(publishImmediately, forKey: "publishImmediately")
        defaults.set(useFilenameAsTitle, forKey: "useFilenameAsTitle"); defaults.set(copyLastURL, forKey: "copyLastURL")
        settingsMessage = ""; message = "设置已保存"; hasSettingsDraft = false; showingSettings = false
        startQueueIfNeeded()
    }
    func openSettings() {
        if !hasSettingsDraft { restoreDraft(); settingsMessage = "" }
        hasSettingsDraft = true; showingSettings = true; refreshLaunchAtLoginStatus()
    }
    func closeSettings() { showingSettings = false }
    func cancelSettings() { restoreDraft(); hasSettingsDraft = false; settingsMessage = ""; showingSettings = false }
    // A click outside the panel hides it without throwing away the settings draft.
    func discardUnsavedSettings() {}

    func chooseImages() {
        guard !isChoosingImages else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要上传的图片"; panel.prompt = "导入图片"
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = SupportedImage.contentTypes
        isChoosingImages = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isChoosingImages = false
                if result == .OK { self.enqueue(urls: panel.urls) }
                self.presentPanel?()
            }
        }
        if let hostWindow { panel.beginSheetModal(for: hostWindow, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
    func enqueue(urls: [URL]) {
        let valid = SupportedImage.filter(urls)
        let existing = Set(items.filter { !$0.status.isFinished }.map(\.sourceURL) + pendingImports.flatMap(\.urls))
        var seen = existing
        let accepted = valid.filter { seen.insert($0.standardizedFileURL).inserted }
        let ignored = urls.count - accepted.count
        guard !accepted.isEmpty else {
            message = valid.isEmpty ? "未识别到图片文件。可选择文件或粘贴图片。" : "这些图片已经在队列或待确认列表中"
            return
        }
        if accepted.count > 1 || !pendingImports.isEmpty {
            pendingImports.append(PendingImport(urls: accepted,
                title: accepted.first?.deletingPathExtension().lastPathComponent ?? ""))
        } else {
            let batch = UUID(); latestBatchId = batch
            items.append(UploadItem(sourceURL: accepted[0], batchId: batch, options: savedOptions))
        }
        message = "已接收 \(accepted.count) 张图片" + (ignored > 0 ? "，忽略 \(ignored) 项不支持或重复的文件" : "")
        if savedToken.isEmpty { openSettings(); settingsMessage = "先保存上传密钥，已导入的图片会保留" }
        else { showingSettings = false; startQueueIfNeeded() }
    }
    func confirmPending() {
        guard let pending = pendingImports.first, !pending.urls.isEmpty else { return }
        guard !savedToken.isEmpty else { openSettings(); settingsMessage = "请先保存上传密钥"; return }
        let batch = pending.id; latestBatchId = batch
        let groupId: UUID? = pending.grouped ? UUID() : nil
        let title = pending.title.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(contentsOf: pending.urls.enumerated().map { index, url in
            UploadItem(sourceURL: url, customTitle: pending.grouped && index == 0 ? title : nil,
                groupId: groupId, isGroupLeader: pending.grouped && index == 0, batchId: batch, options: savedOptions)
        })
        pendingImports.removeFirst(); startQueueIfNeeded()
    }
    func confirmMultiDropSeparate() { pendingGrouped = false; confirmPending() }
    func confirmMultiDropGroup(title: String) { pendingGrouped = true; pendingGroupTitle = title; confirmPending() }
    func cancelMultiDrop() {
        guard !pendingImports.isEmpty else { return }
        let removed = pendingImports.removeFirst(); removed.urls.forEach(cleanManagedImportIfUnused)
    }
    func removePending(_ url: URL) {
        guard !pendingImports.isEmpty else { return }
        pendingImports[0].urls.removeAll { $0 == url }
        if pendingImports[0].urls.isEmpty { pendingImports.removeFirst() }
        cleanManagedImportIfUnused(url)
    }
    func movePending(_ url: URL, by delta: Int) {
        guard !pendingImports.isEmpty, let index = pendingImports[0].urls.firstIndex(of: url) else { return }
        let target = index + delta
        guard pendingImports[0].urls.indices.contains(target) else { return }
        pendingImports[0].urls.swapAt(index, target)
    }
    func addDropFailures(_ names: [String]) {
        guard !names.isEmpty else { return }
        items.append(contentsOf: names.map { UploadItem(failedFileName: $0, reason: "无法读取文件，请在 Finder 中确认文件仍存在") })
        message = "有 \(names.count) 个文件无法读取"
    }
    func retryFailed() { retry(ids: Set(items.filter { $0.isRetryable && $0.status.canRetry }.map(\.id))) }
    func retryItem(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let ids = item.groupId.map { group in Set(items.filter { $0.groupId == group && $0.status.canRetry }.map(\.id)) } ?? [id]
        retry(ids: ids)
    }
    private func retry(ids: Set<UUID>) {
        guard !savedToken.isEmpty else { openSettings(); return }
        for index in items.indices where ids.contains(items[index].id) && items[index].isRetryable && items[index].status.canRetry {
            items[index].status = .waiting; items[index].completedAt = nil
        }
        isPaused = false; startQueueIfNeeded()
    }
    func cancelItem(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.status.isActive else { return }
        let ids = item.isGroupLeader ? Set(items.filter { $0.groupId == item.groupId && !$0.status.isActive }.map(\.id)) : [id]
        for i in items.indices where ids.contains(items[i].id) {
            if case .done = items[i].status { continue }
            items[i].status = .cancelled; items[i].completedAt = Date()
        }
    }
    func togglePause() { isPaused.toggle(); if !isPaused { startQueueIfNeeded() } }
    func clearFinished() {
        let removed = items.filter { if case .done = $0.status { return true }; return $0.status == .cancelled }
        items.removeAll { item in removed.contains { $0.id == item.id } }
        for item in removed { removePrepared(item); cleanManagedImportIfUnused(item.sourceURL) }
    }
    func copyURL(_ item: UploadItem) {
        guard let url = item.result?.url, !url.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
        message = "图片链接已复制"
    }
    func openResult(_ item: UploadItem) {
        guard let value = item.result?.url, let url = URL(string: value), ["https", "http"].contains(url.scheme ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func pasteImages() {
        do { enqueue(urls: try ImageImport.urls(from: .general, storageURL: storageURL)) }
        catch { message = error.localizedDescription }
    }
    func refreshLaunchAtLoginStatus() { launchAtLogin = SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLaunchAtLoginStatus()
            settingsMessage = SMAppService.mainApp.status == .requiresApproval
                ? "请在系统设置 → 通用 → 登录项中允许 Caliph Drop"
                : (launchAtLogin ? "登录启动已开启（立即生效）" : "登录启动已关闭（立即生效）")
        } catch { refreshLaunchAtLoginStatus(); settingsMessage = "登录启动修改失败：\(error.localizedDescription)" }
    }
    func quit() {
        guard hasUnfinished else { didApproveQuit?(); NSApp.terminate(nil); return }
        guard !isShowingQuitConfirmation else { return }
        isShowingQuitConfirmation = true; presentPanel?()
        let alert = NSAlert()
        alert.messageText = "保留任务并退出？"
        alert.informativeText = "未完成任务会保存在本机。下次启动后可继续；正在发送的任务会标记为结果待确认。"
        alert.addButton(withTitle: "继续上传"); alert.addButton(withTitle: "保留任务并退出")
        guard let hostWindow else { isShowingQuitConfirmation = false; return }
        alert.beginSheetModal(for: hostWindow) { [weak self] result in
            guard let self else { return }
            self.isShowingQuitConfirmation = false
            if result == .alertSecondButtonReturn { self.persistQueue(); self.didApproveQuit?(); NSApp.terminate(nil) }
        }
    }
    private func startQueueIfNeeded() {
        guard uploadTask == nil, !savedToken.isEmpty, !isPaused else { return }
        uploadTask = Task { [weak self] in
            guard let self else { return }
            await self.processQueue(); self.uploadTask = nil
        }
    }
    private func processQueue() async {
        while !isPaused, let index = items.firstIndex(where: { $0.status == .waiting }) {
            let item = items[index]; let id = item.id; let options = item.options ?? savedOptions
            var collectionId: String?
            if let group = item.groupId, !item.isGroupLeader {
                collectionId = items.first(where: { $0.groupId == group && $0.isGroupLeader })?.uploadedCollectionId
                guard collectionId != nil else {
                    items[index].status = .blocked("主图尚未上传成功；重试主图后将继续整个合辑")
                    continue
                }
            }
            items[index].status = .processing
            do {
                let processed: ProcessedImage
                if let cached = item.processed, FileManager.default.fileExists(atPath: cached.fileURL.path) {
                    processed = cached
                } else {
                    if item.processed != nil { throw AppError.message("已处理文件丢失。为避免重复记录，请核对网站后重新导入原图。") }
                    let image = try await Task.detached(priority: .userInitiated) {
                        try ImageProcessor.process(sourceURL: item.sourceURL, maxPixel: Int(options.maxPixel),
                            quality: options.quality, preferWebP: options.preferWebP)
                    }.value
                    processed = try cachePrepared(image, id: id)
                }
                guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
                items[i].processed = processed; items[i].status = .uploading
                message = "正在上传 \(item.sourceURL.lastPathComponent)"
                var requestOptions = options
                requestOptions.title = item.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if requestOptions.title.isEmpty && options.useFilename {
                    requestOptions.title = item.sourceURL.deletingPathExtension().lastPathComponent
                }
                let result = try await upload(processed, requestOptions, savedToken, collectionId, id)
                if item.isGroupLeader && (result.collectionId?.isEmpty ?? true) {
                    throw AppError.uncertain("服务器未返回合辑编号。请重试确认结果，附图已暂停。")
                }
                guard let finished = items.firstIndex(where: { $0.id == id }) else { continue }
                items[finished].result = result; items[finished].status = .done(result.url); items[finished].completedAt = Date()
                message = "\(items[finished].resultLabel) · \(processed.sizeSummary)"
                if item.isGroupLeader, let group = item.groupId {
                    for i in items.indices where items[i].groupId == group {
                        if case .blocked = items[i].status { items[i].status = .waiting }
                    }
                }
                if options.copyURL { copyURL(items[finished]) }
            } catch {
                guard let failed = items.firstIndex(where: { $0.id == id }) else { continue }
                let ambiguous = error is URLError || { if case AppError.uncertain = error { return true }; return false }()
                items[failed].status = ambiguous
                    ? .uncertain("网络结果尚未确认。重试会使用同一任务编号：\(error.localizedDescription)")
                    : .failed(error.localizedDescription)
                items[failed].completedAt = Date()
                message = "\(item.sourceURL.lastPathComponent)：\(items[failed].status.label)"
                if case Uploader.UploadError.server(let code, _) = error, code == 401 || code == 403 {
                    isPaused = true; settingsMessage = "上传密钥无效或已过期，请更新后保存并重试"
                }
            }
        }
    }
    private func draftOptions() -> UploadOptions {
        UploadOptions(endpoint: uploadURL, maxPixel: maxPixel, quality: quality, preferWebP: preferWebP,
            publish: publishImmediately, useFilename: useFilenameAsTitle, copyURL: copyLastURL)
    }
    private func restoreDraft() {
        uploadURL = savedOptions.endpoint; token = savedToken; maxPixel = savedOptions.maxPixel
        quality = savedOptions.quality; preferWebP = savedOptions.preferWebP
        publishImmediately = savedOptions.publish; useFilenameAsTitle = savedOptions.useFilename; copyLastURL = savedOptions.copyURL
    }
    private var queueURL: URL { storageURL.appendingPathComponent("queue-v1.json") }
    private func persistQueue() {
        guard persistenceEnabled else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(QueueSnapshot(items: items, pending: pendingImports)).write(to: queueURL, options: .atomic)
        } catch { message = "任务暂时无法保存到本机：\(error.localizedDescription)" }
    }
    private func restoreQueue() {
        guard persistenceEnabled, !restoredQueue else { return }; restoredQueue = true
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return }
        do {
            let snapshot = try JSONDecoder().decode(QueueSnapshot.self, from: Data(contentsOf: queueURL))
            guard snapshot.version == 1 else { throw AppError.message("不支持的队列版本") }
            persistenceEnabled = false
            items = snapshot.items.map { item in
                var copy = item
                if copy.status.isActive { copy.status = .uncertain("上次退出时任务尚未确认，可安全重试同一任务") }
                return copy
            }
            pendingImports = snapshot.pending; latestBatchId = items.last?.batchId
            persistenceEnabled = true; isPaused = hasUnfinished
            if hasUnfinished { message = "已恢复未完成任务，检查后点击继续或重试" }
            persistQueue()
        } catch { persistenceEnabled = false; message = "原队列读取失败，已保留文件：\(error.localizedDescription)" }
    }
    private func cachePrepared(_ image: ProcessedImage, id: UUID) throws -> ProcessedImage {
        defer { try? FileManager.default.removeItem(at: image.fileURL) }
        let folder = storageURL.appendingPathComponent("Prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(id.uuidString + "." + image.fileURL.pathExtension)
        try FileManager.default.moveItem(at: image.fileURL, to: url)
        return ProcessedImage(fileURL: url, fileName: image.fileName, mimeType: image.mimeType,
            originalBytes: image.originalBytes, outputBytes: image.outputBytes, width: image.width, height: image.height)
    }
    private func removePrepared(_ item: UploadItem) {
        guard let url = item.processed?.fileURL,
              url.deletingLastPathComponent().standardizedFileURL == storageURL.appendingPathComponent("Prepared").standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
    private func cleanManagedImportIfUnused(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == storageURL.appendingPathComponent("Imports").standardizedFileURL,
              !items.contains(where: { $0.sourceURL == url }), !pendingImports.flatMap(\.urls).contains(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum AppError: LocalizedError {
    case message(String), uncertain(String)
    var errorDescription: String? { switch self { case .message(let s), .uncertain(let s): return s } }
}

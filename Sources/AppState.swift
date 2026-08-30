import AppKit
import Foundation
import UniformTypeIdentifiers

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
    @Published var items: [UploadItem] = []
    @Published var message: String = "把图片拖到顶部菜单栏的上传图标即可"
    @Published var showingSettings: Bool = false

    private let defaults = UserDefaults.standard
    private let tokenAccount = "caliph-drop-upload-token"
    private var uploadTask: Task<Void, Never>?

    func loadSettings() {
        uploadURL = defaults.string(forKey: "uploadURL") ?? "https://caliph.chengyu.dev/api/drop"
        maxPixel = defaults.object(forKey: "maxPixel") as? Double ?? 2560
        quality = defaults.object(forKey: "quality") as? Double ?? 0.88
        preferWebP = defaults.object(forKey: "preferWebP") as? Bool ?? true
        publishImmediately = defaults.object(forKey: "publishImmediately") as? Bool ?? true
        useFilenameAsTitle = defaults.object(forKey: "useFilenameAsTitle") as? Bool ?? false
        copyLastURL = defaults.object(forKey: "copyLastURL") as? Bool ?? true
        token = (try? KeychainStore.load(account: tokenAccount)) ?? ""
        showingSettings = token.isEmpty
    }

    func saveSettings() {
        defaults.set(uploadURL, forKey: "uploadURL")
        defaults.set(maxPixel, forKey: "maxPixel")
        defaults.set(quality, forKey: "quality")
        defaults.set(preferWebP, forKey: "preferWebP")
        defaults.set(publishImmediately, forKey: "publishImmediately")
        defaults.set(useFilenameAsTitle, forKey: "useFilenameAsTitle")
        defaults.set(copyLastURL, forKey: "copyLastURL")
        try? KeychainStore.save(token, account: tokenAccount)
        message = "设置已保存"
        showingSettings = false
    }

    func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] result in
            guard result == .OK else { return }
            Task { @MainActor in
                self?.enqueue(urls: panel.urls)
            }
        }
    }

    func enqueue(urls: [URL]) {
        let allowed = Set(["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "tif", "tiff"])
        let filtered = urls.filter { allowed.contains($0.pathExtension.lowercased()) }
        guard !filtered.isEmpty else {
            message = "没有识别到可上传的图片"
            return
        }

        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            items.append(contentsOf: filtered.map(UploadItem.init))
            showingSettings = true
            message = "第一次使用：先填入 CALIPH_DROP_TOKEN"
            return
        }

        items.append(contentsOf: filtered.map(UploadItem.init))
        startQueueIfNeeded()
    }

    func retryFailed() {
        for index in items.indices {
            if case .failed = items[index].status {
                items[index].status = .waiting
            }
        }
        startQueueIfNeeded()
    }

    func clearFinished() {
        items.removeAll {
            switch $0.status {
            case .done, .failed: return true
            default: return false
            }
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
            let id = items[index].id
            let sourceURL = items[index].sourceURL
            items[index].status = .processing
            message = "正在处理 \(sourceURL.lastPathComponent)…"

            do {
                let processed = try ImageProcessor.process(
                    sourceURL: sourceURL,
                    maxPixel: Int(maxPixel),
                    quality: quality,
                    preferWebP: preferWebP
                )

                guard let currentIndex = items.firstIndex(where: { $0.id == id }) else { continue }
                items[currentIndex].status = .uploading
                message = "正在上传 \(processed.fileName)…"

                let title = useFilenameAsTitle
                    ? sourceURL.deletingPathExtension().lastPathComponent
                    : ""

                let result = try await Uploader.upload(
                    image: processed,
                    endpoint: uploadURL,
                    token: token,
                    title: title,
                    publish: publishImmediately
                )
                try? FileManager.default.removeItem(at: processed.fileURL)

                guard let finishedIndex = items.firstIndex(where: { $0.id == id }) else { continue }
                items[finishedIndex].status = .done(result.url)

                let before = ByteCountFormatter.string(fromByteCount: processed.originalBytes, countStyle: .file)
                let after = ByteCountFormatter.string(fromByteCount: processed.outputBytes, countStyle: .file)
                message = "✓ \(sourceURL.lastPathComponent)：\(before) → \(after)"

                if copyLastURL, let url = result.url, !url.isEmpty {
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
}

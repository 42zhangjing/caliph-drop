import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ImageImport {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        !SupportedImage.filter(fileURLs(from: pasteboard)).isEmpty || pasteboard.availableType(from: [.png, .tiff]) != nil
    }
    static func urls(from pasteboard: NSPasteboard, storageURL: URL) throws -> [URL] {
        let files = fileURLs(from: pasteboard)
        if !files.isEmpty { return files }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) {
                return [try store(data, extension: type == .png ? "png" : "tiff", storageURL: storageURL)]
            }
        }
        throw AppError.message("这里没有可读取的图片。请拖入 Finder 图片文件，或复制图片后粘贴。")
    }
    static func store(_ data: Data, extension ext: String, storageURL: URL) throws -> URL {
        guard !data.isEmpty, data.count <= 200 * 1024 * 1024 else { throw AppError.message("图片为空或超过 200 MB") }
        let folder = storageURL.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("粘贴图片-\(UUID().uuidString.prefix(8)).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }
    @MainActor static func load(_ providers: [NSItemProvider], into state: AppState) -> Bool {
        guard !providers.isEmpty else { return false }
        let storage = state.storageURL
        Task {
            var urls: [URL] = []; var failed: [String] = []
            for provider in providers {
                do {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let url: URL = try await withCheckedThrowingContinuation { continuation in
                            provider.loadObject(ofClass: NSURL.self) { object, error in
                                if let url = object as? URL { continuation.resume(returning: url) }
                                else { continuation.resume(throwing: error ?? AppError.message("无法读取文件")) }
                            }
                        }
                        urls.append(url)
                    } else if let type = [UTType.png, .tiff].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                        let data: Data = try await withCheckedThrowingContinuation { continuation in
                            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                                if let data { continuation.resume(returning: data) }
                                else { continuation.resume(throwing: error ?? AppError.message("无法读取图片")) }
                            }
                        }
                        urls.append(try store(data, extension: type == .png ? "png" : "tiff", storageURL: storage))
                    } else { failed.append(provider.suggestedName ?? "不支持的文件") }
                } catch { failed.append(provider.suggestedName ?? "无法读取的图片") }
            }
            if !urls.isEmpty { state.enqueue(urls: urls) }
            state.addDropFailures(failed)
        }
        return true
    }
}

@MainActor
private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()
    init() { cache.countLimit = 240; cache.totalCostLimit = 32 * 1024 * 1024 }
    func image(_ url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }.value
        guard let image else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(result, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return result
    }
}

struct ImageThumbnail: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView(); view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true; view.layer?.cornerRadius = 7; view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        view.setAccessibilityLabel(url.lastPathComponent)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        let identity = NSUserInterfaceItemIdentifier(url.absoluteString)
        guard view.identifier != identity else { return }
        view.identifier = identity
        view.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "图片预览")
        Task { @MainActor [weak view] in
            let image = await ThumbnailCache.shared.image(url)
            guard let view, view.identifier == identity else { return }
            if let image { view.image = image }
        }
    }
}

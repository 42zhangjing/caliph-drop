import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageProcessor {
    enum ProcessingError: LocalizedError {
        case cannotOpen
        case cannotCreateThumbnail
        case cannotEncode

        var errorDescription: String? {
            switch self {
            case .cannotOpen: return "无法读取图片"
            case .cannotCreateThumbnail: return "无法生成压缩图片"
            case .cannotEncode: return "无法编码图片"
            }
        }
    }

    static func process(sourceURL: URL, maxPixel: Int, quality: Double, preferWebP: Bool) throws -> ProcessedImage {
        let originalValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let originalBytes = Int64(originalValues.fileSize ?? 0)

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw ProcessingError.cannotOpen
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(320, maxPixel),
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ProcessingError.cannotCreateThumbnail
        }

        let supportedDestinations = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        let canWriteWebP = supportedDestinations.contains(UTType.webP.identifier)
        let outputType: UTType = (preferWebP && canWriteWebP) ? .webP : .jpeg
        let outputExt = outputType == .webP ? "webp" : "jpg"
        let outputMime = outputType == .webP ? "image/webp" : "image/jpeg"
        let base = safeBaseName(sourceURL.deletingPathExtension().lastPathComponent)

        let encodedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caliph-drop-\(UUID().uuidString)-\(base).\(outputExt)")

        guard let destination = CGImageDestinationCreateWithURL(
            encodedURL as CFURL,
            outputType.identifier as CFString,
            1,
            nil
        ) else {
            throw ProcessingError.cannotEncode
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.45), 0.98)
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ProcessingError.cannotEncode
        }

        let outputValues = try encodedURL.resourceValues(forKeys: [.fileSizeKey])
        let encodedBytes = Int64(outputValues.fileSize ?? 0)

        let outputWidth = image.width
        let outputHeight = image.height

        // Match the website's existing behavior: if compression is not smaller, keep the original.
        if originalBytes > 0, encodedBytes >= originalBytes {
            try? FileManager.default.removeItem(at: encodedURL)
            let originalExt = sourceURL.pathExtension.lowercased().isEmpty ? "img" : sourceURL.pathExtension.lowercased()
            let copyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("caliph-drop-\(UUID().uuidString)-\(base).\(originalExt)")
            try FileManager.default.copyItem(at: sourceURL, to: copyURL)
            return ProcessedImage(
                fileURL: copyURL,
                fileName: "\(base).\(originalExt)",
                mimeType: mimeType(forExtension: originalExt),
                originalBytes: originalBytes,
                outputBytes: originalBytes,
                width: outputWidth,
                height: outputHeight
            )
        }

        return ProcessedImage(
            fileURL: encodedURL,
            fileName: "\(base).\(outputExt)",
            mimeType: outputMime,
            originalBytes: originalBytes,
            outputBytes: encodedBytes,
            width: outputWidth,
            height: outputHeight
        )
    }

    private static func safeBaseName(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "image" : String(cleaned.prefix(80))
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "avif": return "image/avif"
        case "tif", "tiff": return "image/tiff"
        default: return "application/octet-stream"
        }
    }
}

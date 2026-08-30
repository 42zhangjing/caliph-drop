import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageProcessor {
    enum ProcessingError: LocalizedError {
        case cannotOpen
        case inputTooLarge
        case pixelCountTooLarge
        case multipleFramesUnsupported(Int)
        case cannotCreateThumbnail
        case cannotEncode

        var errorDescription: String? {
            switch self {
            case .cannotOpen: return "无法读取图片"
            case .inputTooLarge: return "原图超过 200 MB，请先缩小后再上传"
            case .pixelCountTooLarge: return "原图超过 1 亿像素，请先缩小后再上传"
            case let .multipleFramesUnsupported(count): return "检测到 \(count) 帧内容；当前仅支持单帧图片，已停止上传以避免丢失内容"
            case .cannotCreateThumbnail: return "无法生成压缩图片"
            case .cannotEncode: return "无法编码图片"
            }
        }
    }

    static func process(sourceURL: URL, maxPixel: Int, quality: Double, preferWebP: Bool) throws -> ProcessedImage {
        let originalValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let originalBytes = Int64(originalValues.fileSize ?? 0)
        guard originalBytes <= 200 * 1024 * 1024 else {
            throw ProcessingError.inputTooLarge
        }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw ProcessingError.cannotOpen
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount == 1 else {
            throw ProcessingError.multipleFramesUnsupported(frameCount)
        }
        let sourceInfo = sourceInfo(from: source)
        if let width = sourceInfo.width, let height = sourceInfo.height,
           Int64(width) * Int64(height) > 100_000_000 {
            throw ProcessingError.pixelCountTooLarge
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
        let outputType: UTType
        if preferWebP && canWriteWebP {
            outputType = .webP
        } else if hasAlpha(image) {
            outputType = .png
        } else {
            outputType = .jpeg
        }
        let outputExt: String
        let outputMime: String
        switch outputType {
        case .webP:
            outputExt = "webp"
            outputMime = "image/webp"
        case .png:
            outputExt = "png"
            outputMime = "image/png"
        default:
            outputExt = "jpg"
            outputMime = "image/jpeg"
        }
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
            try? FileManager.default.removeItem(at: encodedURL)
            throw ProcessingError.cannotEncode
        }

        let outputValues = try encodedURL.resourceValues(forKeys: [.fileSizeKey])
        let encodedBytes = Int64(outputValues.fileSize ?? 0)

        let outputWidth = image.width
        let outputHeight = image.height

        // Keep a small, already-efficient original only when doing so does not
        // defeat resizing and does not preserve private camera/location metadata.
        let originalFits = max(sourceInfo.width ?? 0, sourceInfo.height ?? 0) <= max(320, maxPixel)
        if originalBytes > 0,
           encodedBytes >= originalBytes,
           originalFits,
           !sourceInfo.hasPrivateMetadata {
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
                width: sourceInfo.width ?? outputWidth,
                height: sourceInfo.height ?? outputHeight
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

    private struct SourceInfo {
        let width: Int?
        let height: Int?
        let hasPrivateMetadata: Bool
    }

    private static func sourceInfo(from source: CGImageSource) -> SourceInfo {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            swap(&width, &height)
        }

        let privateMetadataKeys: [CFString] = [
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyExifDictionary,
            kCGImagePropertyIPTCDictionary,
            kCGImagePropertyTIFFDictionary
        ]
        let hasPrivateMetadata = privateMetadataKeys.contains { properties[$0] != nil }
        return SourceInfo(width: width, height: height, hasPrivateMetadata: hasPrivateMetadata)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return false
        }
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

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum LiveTestError: LocalizedError {
    case notAuthorized
    case missingToken
    case cannotCreateFixture
    case publicMediaUnavailable
    case collectionNotVisible

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "必须显式设置 CALIPH_DROP_ALLOW_LIVE_TEST=1"
        case .missingToken: return "Keychain 中没有 Caliph Drop Token"
        case .cannotCreateFixture: return "无法创建上传验证图片"
        case .publicMediaUnavailable: return "上传后的公开图片不可访问"
        case .collectionNotVisible: return "公开档案接口还没有返回验证记录"
        }
    }
}

@main
private struct LiveUploadSmoke {
    static func main() async throws {
        if ProcessInfo.processInfo.environment["CALIPH_DROP_RENDER_FIXTURE"] == "1" {
            let previewURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("caliph-drop-0.3-live-verification-preview.png")
            try makeVerificationCard(at: previewURL)
            print(previewURL.path)
            return
        }
        guard ProcessInfo.processInfo.environment["CALIPH_DROP_ALLOW_LIVE_TEST"] == "1" else {
            throw LiveTestError.notAuthorized
        }
        guard let token = try KeychainStore.load(account: "caliph-drop-upload-token"), !token.isEmpty else {
            throw LiveTestError.missingToken
        }

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caliph-drop-0.3-live-verification.png")
        try makeVerificationCard(at: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let processed = try ImageProcessor.process(
            sourceURL: sourceURL,
            maxPixel: 2560,
            quality: 0.88,
            preferWebP: true
        )
        defer { try? FileManager.default.removeItem(at: processed.fileURL) }

        let title = "Caliph Drop 0.3 上传验证"
        let result = try await Uploader.upload(
            image: processed,
            endpoint: "https://caliph.chengyu.dev/api/drop",
            token: token,
            title: title,
            publish: true
        )
        guard let publicURL = result.url, let mediaURL = URL(string: publicURL) else {
            throw LiveTestError.publicMediaUnavailable
        }

        let (_, mediaResponse) = try await URLSession.shared.data(from: mediaURL)
        guard let mediaHTTP = mediaResponse as? HTTPURLResponse,
              (200...299).contains(mediaHTTP.statusCode),
              mediaHTTP.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image/") == true else {
            throw LiveTestError.publicMediaUnavailable
        }

        var components = URLComponents(string: "https://caliph.chengyu.dev/api/collections")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "verify", value: UUID().uuidString)
        ]
        let (listData, listResponse) = try await URLSession.shared.data(from: components.url!)
        guard let listHTTP = listResponse as? HTTPURLResponse,
              (200...299).contains(listHTTP.statusCode),
              let payload = try JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let items = payload["items"] as? [[String: Any]],
              items.contains(where: { $0["title"] as? String == title }) else {
            throw LiveTestError.collectionNotVisible
        }

        print("✓ Live upload verified: \(publicURL)")
    }

    private static func makeVerificationCard(at url: URL) throws {
        let width = 1200
        let height = 800
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw LiveTestError.cannotCreateFixture
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor(calibratedRed: 0.075, green: 0.067, blue: 0.055, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(calibratedRed: 0.94, green: 0.89, blue: 0.78, alpha: 1).setFill()
        NSRect(x: 90, y: 90, width: 1020, height: 620).fill()
        NSColor(calibratedRed: 0.68, green: 0.39, blue: 0.12, alpha: 1).setFill()
        NSRect(x: 90, y: 90, width: 18, height: 620).fill()

        draw("CALIPH DROP 0.3", at: NSPoint(x: 170, y: 465), size: 70, color: .black)
        draw(
            "UPLOAD VERIFIED",
            at: NSPoint(x: 174, y: 350),
            size: 38,
            color: NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.10, alpha: 1)
        )
        draw("2026-08-30", at: NSPoint(x: 176, y: 245), size: 25, color: NSColor(calibratedWhite: 0.28, alpha: 1))
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw LiveTestError.cannotCreateFixture
        }
        try data.write(to: url, options: .atomic)
    }

    private static func draw(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}

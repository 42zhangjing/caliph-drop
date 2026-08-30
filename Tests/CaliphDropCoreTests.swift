import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): return message
        }
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw TestFailure.assertion("MockURLProtocol handler is missing")
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@main
private struct CaliphDropCoreTests {
    static func main() async throws {
        try testSupportedExtensions()
        try testResizeAndDimensions()
        try testTransparentImageStaysTransparent()
        try testPrivateMetadataIsRemoved()
        try testMultiFrameImageIsRejected()
        try testEndpointValidation()
        try await testUploaderContractAndErrors()
        print("✓ Caliph Drop core tests passed (7/7)")
    }

    private static func testSupportedExtensions() throws {
        let urls = ["one.jpg", "two.AVIF", "three.gif", "four.txt"].map(URL.init(fileURLWithPath:))
        let names = SupportedImage.filter(urls).map(\.lastPathComponent)
        try require(names == ["one.jpg", "two.AVIF"], "supported image filtering is inconsistent")
    }

    private static func testResizeAndDimensions() throws {
        let input = temporaryURL(extension: "jpg")
        try makeImage(
            at: input,
            width: 900,
            height: 450,
            alpha: false,
            includeGPS: false,
            type: .jpeg,
            quality: 0.10
        )
        defer { try? FileManager.default.removeItem(at: input) }

        let result = try ImageProcessor.process(sourceURL: input, maxPixel: 320, quality: 0.88, preferWebP: false)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        try require(result.width == 320 && result.height == 160, "resized dimensions should be 320 × 160")
        try require(FileManager.default.fileExists(atPath: result.fileURL.path), "processed file was not created")
        guard let outputSource = CGImageSourceCreateWithURL(result.fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any] else {
            throw TestFailure.assertion("resized output dimensions could not be read")
        }
        let actualWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let actualHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        try require(actualWidth == result.width && actualHeight == result.height, "reported dimensions must match uploaded pixels")
    }

    private static func testTransparentImageStaysTransparent() throws {
        let input = temporaryURL(extension: "png")
        try makeImage(at: input, width: 400, height: 260, alpha: true, includeGPS: false, type: .png)
        defer { try? FileManager.default.removeItem(at: input) }

        let result = try ImageProcessor.process(sourceURL: input, maxPixel: 400, quality: 0.88, preferWebP: false)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        try require(result.mimeType == "image/png", "transparent images must not fall back to JPEG")
    }

    private static func testPrivateMetadataIsRemoved() throws {
        let input = temporaryURL(extension: "jpg")
        try makeImage(
            at: input,
            width: 400,
            height: 240,
            alpha: false,
            includeGPS: true,
            type: .jpeg,
            quality: 0.10
        )
        defer { try? FileManager.default.removeItem(at: input) }

        let result = try ImageProcessor.process(sourceURL: input, maxPixel: 400, quality: 0.88, preferWebP: false)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        guard let source = CGImageSourceCreateWithURL(result.fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw TestFailure.assertion("processed metadata could not be read")
        }
        try require(properties[kCGImagePropertyGPSDictionary] == nil, "GPS metadata should be removed")
    }

    private static func testMultiFrameImageIsRejected() throws {
        let input = temporaryURL(extension: "tiff")
        try makeMultiFrameTIFF(at: input)
        defer { try? FileManager.default.removeItem(at: input) }

        do {
            _ = try ImageProcessor.process(sourceURL: input, maxPixel: 400, quality: 0.88, preferWebP: false)
            throw TestFailure.assertion("multi-frame images must not be silently flattened")
        } catch let ImageProcessor.ProcessingError.multipleFramesUnsupported(count) {
            try require(count == 2, "multi-frame error should report the source frame count")
        }
    }

    private static func testEndpointValidation() throws {
        try require(UploadEndpoint.url(from: "https://example.test/api/drop") != nil, "valid HTTPS endpoint was rejected")
        try require(UploadEndpoint.url(from: "http://localhost:8787/api/drop") != nil, "localhost HTTP should be allowed for development")
        try require(UploadEndpoint.url(from: "https:///api/drop") == nil, "hostless HTTPS endpoint was accepted")
        try require(UploadEndpoint.url(from: "http://example.test/api/drop") == nil, "remote HTTP endpoint was accepted")
    }

    private static func testUploaderContractAndErrors() async throws {
        let file = temporaryURL(extension: "jpg")
        try makeImage(at: file, width: 64, height: 64, alpha: false, includeGPS: false, type: .jpeg)
        defer { try? FileManager.default.removeItem(at: file) }
        let image = ProcessedImage(
            fileURL: file,
            fileName: "test.jpg",
            mimeType: "image/jpeg",
            originalBytes: 10,
            outputBytes: 10,
            width: 64,
            height: 64
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockURLProtocol.handler = { request in
            try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret", "authorization header is missing")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"ok\":true,\"url\":\"https://example.test/media/1\"}".utf8))
        }
        let result = try await Uploader.upload(
            image: image,
            endpoint: "https://example.test/api/drop",
            token: "secret",
            title: "",
            publish: true,
            session: session
        )
        try require(result.url == "https://example.test/media/1", "success response URL was not parsed")

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"error\":\"Token 不正确\"}".utf8))
        }
        do {
            _ = try await Uploader.upload(
                image: image,
                endpoint: "https://example.test/api/drop",
                token: "wrong",
                title: "",
                publish: true,
                session: session
            )
            throw TestFailure.assertion("401 response should fail")
        } catch let Uploader.UploadError.server(code, message) {
            try require(code == 401 && message == "Token 不正确", "server error was not normalized")
        }
    }

    private static func makeImage(
        at url: URL,
        width: Int,
        height: Int,
        alpha: Bool,
        includeGPS: Bool,
        type: UTType,
        quality: Double? = nil
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = alpha
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { throw TestFailure.assertion("test CGContext creation failed") }

        context.setFillColor(CGColor(red: 0.12, green: 0.10, blue: 0.08, alpha: alpha ? 0.65 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw TestFailure.assertion("test image destination creation failed")
        }

        var properties: [CFString: Any] = [:]
        if includeGPS {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 31.2304,
                kCGImagePropertyGPSLongitude: 121.4737
            ]
        }
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "test image encoding failed")
    }

    private static func makeMultiFrameTIFF(at url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 80,
            height: 60,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw TestFailure.assertion("multi-frame CGContext creation failed") }
        context.setFillColor(CGColor(red: 0.2, green: 0.1, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.tiff.identifier as CFString,
                2,
                nil
              ) else {
            throw TestFailure.assertion("multi-frame destination creation failed")
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "multi-frame TIFF encoding failed")
    }

    private static func temporaryURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("caliph-drop-test-\(UUID().uuidString).\(fileExtension)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure.assertion(message) }
    }
}

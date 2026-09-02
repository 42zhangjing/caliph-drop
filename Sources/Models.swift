import Foundation
import UniformTypeIdentifiers

enum SupportedImage {
    static let fileExtensions = Set([
        "jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "tif", "tiff"
    ])

    static func filter(_ urls: [URL]) -> [URL] {
        urls.filter { fileExtensions.contains($0.pathExtension.lowercased()) }
    }

    static let contentTypes: [UTType] = fileExtensions
        .compactMap { UTType(filenameExtension: $0) }
        .reduce(into: []) { types, type in
            if !types.contains(type) { types.append(type) }
        }
}

enum UploadEndpoint {
    static func url(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil else { return nil }

        if scheme == "https" { return components.url }
        let localHosts = Set(["localhost", "127.0.0.1", "::1"])
        guard scheme == "http", localHosts.contains(host) else { return nil }
        return components.url
    }
}

enum UploadActivity: Equatable {
    case idle
    case working
    case success
    case failed
}

enum UploadItemStatus: Equatable {
    case waiting
    case processing
    case uploading
    case done(String?)
    case failed(String)

    var label: String {
        switch self {
        case .waiting: return "等待"
        case .processing: return "压缩中"
        case .uploading: return "上传中"
        case .done: return "完成"
        case .failed: return "失败"
        }
    }
}

struct UploadItem: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let isRetryable: Bool
    var status: UploadItemStatus
    let createdAt: Date
    var customTitle: String?
    var groupId: UUID?
    var isGroupLeader: Bool

    var formattedTime: String {
        Self.timeFormatter.string(from: createdAt)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(
        sourceURL: URL,
        customTitle: String? = nil,
        groupId: UUID? = nil,
        isGroupLeader: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.isRetryable = true
        self.status = .waiting
        self.createdAt = createdAt
        self.customTitle = customTitle
        self.groupId = groupId
        self.isGroupLeader = isGroupLeader
    }

    init(failedFileName: String, reason: String, createdAt: Date = Date()) {
        self.id = UUID()
        self.sourceURL = URL(fileURLWithPath: failedFileName)
        self.isRetryable = false
        self.status = .failed(reason)
        self.createdAt = createdAt
        self.customTitle = nil
        self.groupId = nil
        self.isGroupLeader = false
    }
}

struct ProcessedImage: Sendable {
    let fileURL: URL
    let fileName: String
    let mimeType: String
    let originalBytes: Int64
    let outputBytes: Int64
    let width: Int?
    let height: Int?
}

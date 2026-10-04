import Foundation
import UniformTypeIdentifiers

enum SupportedImage {
    static let fileExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "tif", "tiff"])
    static func filter(_ urls: [URL]) -> [URL] {
        urls.filter { $0.isFileURL && fileExtensions.contains($0.pathExtension.lowercased()) }
    }
    static let contentTypes: [UTType] = fileExtensions.compactMap { UTType(filenameExtension: $0) }
        .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
}

enum UploadEndpoint {
    static func url(from value: String) -> URL? {
        guard let c = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil else { return nil }
        if scheme == "https" { return c.url }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host) ? c.url : nil
    }
}

enum UploadActivity: Equatable { case idle, working, success, failed }
enum UploadItemStatus: Equatable, Codable {
    case waiting, processing, uploading, blocked(String), uncertain(String), cancelled
    case done(String?), failed(String)
    var label: String {
        switch self {
        case .waiting: return "等待"
        case .processing: return "压缩中"
        case .uploading: return "上传中"
        case .blocked: return "等待主图"
        case .uncertain: return "结果待确认"
        case .cancelled: return "已取消"
        case .done: return "已上传"
        case .failed: return "失败"
        }
    }
    var isActive: Bool {
        switch self { case .processing, .uploading: return true; default: return false }
    }
    var isFinished: Bool {
        switch self { case .done, .failed, .uncertain, .blocked, .cancelled: return true; default: return false }
    }
    var canRetry: Bool {
        switch self { case .failed, .uncertain, .blocked: return true; default: return false }
    }
    var error: String? {
        switch self { case .failed(let s), .uncertain(let s), .blocked(let s): return s; default: return nil }
    }
}

struct UploadOptions: Codable, Equatable, Sendable {
    var endpoint = "https://caliph.chengyu.dev/api/drop"
    var maxPixel = 2560.0
    var quality = 0.88
    var preferWebP = true
    var publish = true
    var useFilename = false
    var copyURL = true
    var title = ""
}

struct UploadItem: Identifiable, Equatable, Codable {
    let id: UUID
    let sourceURL: URL
    let isRetryable: Bool
    var status: UploadItemStatus
    let createdAt: Date
    var completedAt: Date?
    var customTitle: String?
    var groupId: UUID?
    var isGroupLeader: Bool
    var batchId: UUID
    var options: UploadOptions?
    var processed: ProcessedImage?
    var result: UploadResult?
    var uploadedCollectionId: String? { result?.collectionId }
    var formattedTime: String { Self.timeFormatter.string(from: completedAt ?? createdAt) }
    var timeLabel: String { (completedAt == nil ? "加入 " : "完成 ") + formattedTime }
    var resultLabel: String {
        guard case .done = status else { return status.label }
        if result?.needsReview == true { return "草稿 · 待补标题" }
        switch result?.publicationStatus {
        case "published": return "已发布"
        case "draft": return "已存草稿"
        default: return "已上传"
        }
    }
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    init(sourceURL: URL, customTitle: String? = nil, groupId: UUID? = nil,
         isGroupLeader: Bool = false, createdAt: Date = Date(), batchId: UUID = UUID(), options: UploadOptions? = nil) {
        id = UUID(); self.sourceURL = sourceURL; isRetryable = true; status = .waiting
        self.createdAt = createdAt; self.customTitle = customTitle; self.groupId = groupId
        self.isGroupLeader = isGroupLeader; self.batchId = batchId; self.options = options
    }
    init(failedFileName: String, reason: String, createdAt: Date = Date()) {
        id = UUID(); sourceURL = URL(fileURLWithPath: failedFileName); isRetryable = false
        status = .failed(reason); self.createdAt = createdAt; isGroupLeader = false; batchId = UUID()
    }
}
struct ProcessedImage: Sendable, Codable, Equatable {
    let fileURL: URL
    let fileName: String
    let mimeType: String
    let originalBytes: Int64
    let outputBytes: Int64
    let width: Int?
    let height: Int?
    var sizeSummary: String {
        ByteCountFormatter.string(fromByteCount: originalBytes, countStyle: .file) + " → " +
        ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)
    }
}
struct UploadResult: Sendable, Codable, Equatable {
    let url: String?
    let collectionId: String?
    var publicationStatus: String? = nil
    var needsReview: Bool = false
    var slug: String? = nil
}
struct PendingImport: Identifiable, Codable {
    var id = UUID()
    var urls: [URL]
    var title: String
    var grouped = false
}
struct QueueSnapshot: Codable {
    var version = 1
    var items: [UploadItem]
    var pending: [PendingImport]
}

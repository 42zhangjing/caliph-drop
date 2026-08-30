import Foundation

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
    var status: UploadItemStatus

    init(sourceURL: URL) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.status = .waiting
    }
}

struct ProcessedImage {
    let fileURL: URL
    let fileName: String
    let mimeType: String
    let originalBytes: Int64
    let outputBytes: Int64
}

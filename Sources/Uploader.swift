import Foundation

struct UploadResult {
    let url: String?
}

struct Uploader {
    enum UploadError: LocalizedError {
        case invalidEndpoint
        case fileTooLarge(Int64)
        case server(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "上传地址不正确"
            case let .fileTooLarge(bytes):
                let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                return "处理后的文件仍有 \(size)，超过 50 MB 上传上限"
            case let .server(code, text): return "服务器返回 \(code)：\(text)"
            case .invalidResponse: return "服务器返回的数据无法解析"
            }
        }
    }

    static func upload(
        image: ProcessedImage,
        endpoint: String,
        token: String,
        title: String,
        publish: Bool,
        session: URLSession = .shared
    ) async throws -> UploadResult {
        guard let url = UploadEndpoint.url(from: endpoint) else {
            throw UploadError.invalidEndpoint
        }
        let fileSize = Int64(try image.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard fileSize <= 50 * 1024 * 1024 else {
            throw UploadError.fileTooLarge(fileSize)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue(image.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(percentEncodeHeader(image.fileName), forHTTPHeaderField: "X-File-Name")
        request.setValue(percentEncodeHeader(title), forHTTPHeaderField: "X-Title")
        request.setValue(publish ? "1" : "0", forHTTPHeaderField: "X-Publish")
        if let width = image.width {
            request.setValue("\(width)", forHTTPHeaderField: "X-Media-Width")
        }
        if let height = image.height {
            request.setValue("\(height)", forHTTPHeaderField: "X-Media-Height")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.upload(for: request, fromFile: image.fileURL)
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            throw UploadError.server(http.statusCode, serverMessage(from: data))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool != false,
              let publicURL = json["url"] as? String,
              !publicURL.isEmpty else { throw UploadError.invalidResponse }
        return UploadResult(url: publicURL)
    }

    private static func percentEncodeHeader(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }

    private static func serverMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String,
           !error.isEmpty {
            return String(error.prefix(320))
        }
        let text = String(data: data, encoding: .utf8) ?? "未知错误"
        return String(text.prefix(320))
    }
}

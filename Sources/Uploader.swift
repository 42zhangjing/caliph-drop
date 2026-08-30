import Foundation

struct UploadResult {
    let url: String?
}

struct Uploader {
    enum UploadError: LocalizedError {
        case invalidEndpoint
        case server(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "上传地址不正确"
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
        publish: Bool
    ) async throws -> UploadResult {
        guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw UploadError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue(image.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(percentEncodeHeader(image.fileName), forHTTPHeaderField: "X-File-Name")
        request.setValue(percentEncodeHeader(title), forHTTPHeaderField: "X-Title")
        request.setValue(publish ? "1" : "0", forHTTPHeaderField: "X-Publish")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try Data(contentsOf: image.fileURL)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)?.prefix(320) ?? ""
            throw UploadError.server(http.statusCode, String(text))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return UploadResult(url: nil)
        }
        return UploadResult(url: json["url"] as? String)
    }

    private static func percentEncodeHeader(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }
}

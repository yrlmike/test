import Foundation

final class APIService {
    static let shared = APIService()
    private init() {}

    struct Config {
        var baseURL: String
        var apiKey: String
        var modelName: String
    }

    // ✅ 新增 systemPrompt 参数
    func ask(question: String, systemPrompt: String, config: Config) async throws -> String {
        let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/chat/completions") else {
            throw NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API Base URL"])
        }

        let cleanKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "APIService", code: -2, userInfo: [NSLocalizedDescriptionKey: "未填写 API Key"])
        }

        let cleanModel = config.modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        // ✅ 将前端的自定义提示词融合到请求里
        let combinedPrompt = """
        \(systemPrompt)

        ==========
        屏幕识别内容：
        \(question)
        """

        let payload: [String: Any] = [
            "model": cleanModel,
            "messages": [
                ["role": "user", "content": combinedPrompt]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResp = response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
            let errBody = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw NSError(domain: "APIService", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "API 请求失败: \(errBody)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "APIService", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法解析模型返回内容"])
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

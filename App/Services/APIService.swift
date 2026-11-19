import Foundation

final class APIService {
    static let shared = APIService()
    private init() {}

    struct Config {
        var baseURL: String
        var apiKey: String
        var modelName: String
    }

    func ask(question: String, config: Config) async throws -> String {
        let cleanBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanBase)/chat/completions") else {
            throw NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 25

        let body: [String: Any] = [
            "model": config.modelName,
            "messages": [
                [
                    "role": "system",
                    "content": "你是一个精准的屏幕解题与知识助手。用户会发给你屏幕 OCR 识别出的文本（可能包含界面按钮等杂音，请自动忽略）。请直接给出核心答案，并用不超过3行简明扼要地解释原因，方便在手机小窗中快速阅读。"
                ],
                [
                    "role": "user",
                    "content": question
                ]
            ],
            "temperature": 0.2,
            "max_tokens": 400
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResp = response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw NSError(domain: "APIService", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "API 请求失败: \(errText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "APIService", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法解析模型返回内容"])
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
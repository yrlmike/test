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

        // 将规则直接合并到 user 消息中，避免部分 MaaS 模型拒绝 system 角色
        let combinedPrompt = """
        你是一个手机悬浮窗极速答题助手。根据以下屏幕识别出的文本作答：
        1. 严禁使用任何 Markdown 格式符号（不要出现 **、*、#、`、- 等符号），只输出纯文本。
        2. 第一行直接给出最终核心答案（单选写【单选】X，多选写【多选】XXXX），独占一行。
        3. 第二行起用不超过 2 句话说明关键原因，总字数严格控制在 70 字以内，不要客套话或重复题目。

        屏幕识别内容：
        \(question)
        """

        // 精简请求体，仅保留所有模型 100% 兼容的 model 与 messages 字段
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

        let cleaned = content
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }
}

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

        let systemPrompt = """
        你是一个手机悬浮窗极速答题助手。用户会发给你屏幕 OCR 识别出的文本（可能包含界面按钮杂音，请自动忽略，只针对核心题目作答）。
        必须严格遵守以下输出规则：
        1. 严禁使用任何 Markdown 格式符号（绝对不要出现 **、*、#、`、- 等符号），只输出纯文本。
        2. 第一行直接给出最终核心答案（如选项字母、计算结果或核心定义），独占一行。
        3. 第二行起用不超过 2 句话说明关键原因，总字数严格控制在 70 字以内，方便在手机小窗口一眼看清。
        4. 不要任何客套话、开场白或重复题目。
        """

        let payload: [String: Any] = [
            "model": config.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": question]
            ],
            "temperature": 0.2,
            "max_tokens": 180
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
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

        // 双重保险：自动清洗掉模型偶尔残余的 Markdown 星号与井号，保证悬浮窗纯文本整洁
        let cleaned = content
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }
}

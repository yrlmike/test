import Foundation

enum AppGroup {
    static let localPort: UInt16 = 45678

    static func writeQuestion(_ text: String) {
        guard let url = URL(string: "http://127.0.0.1:\(localPort)/question"),
              let body = text.data(using: .utf8) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 3.0

        URLSession.shared.dataTask(with: request).resume()
    }

    static func writeStatus(_ status: String) {
        // 状态更新保持轻量化，避免频繁请求
    }
}

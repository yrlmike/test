import Foundation

enum AppGroup {
    static let darwinNotificationName = "com.screensolver.newQuestion"
    private static let questionKey = "latest_question"
    private static let questionTimeKey = "latest_question_ts"
    private static let statusKey = "solver_status"

    // 按优先级探测当前签名实际可用的 App Group 容器
    static let id: String = {
        let candidates = [
            "group.com.screensolver.shared",
            "group.com.screensolver.shared.KVZNVCA89R",
            "group.com.screensolver.app.KVZNVCA89R"
        ]
        for groupID in candidates {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil {
                return groupID
            }
        }
        return "group.com.screensolver.shared"
    }()

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: id)
    }

    static func writeQuestion(_ text: String) {
        defaults?.set(text, forKey: questionKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: questionTimeKey)
        defaults?.synchronize()
    }

    static func readQuestion() -> (text: String, timestamp: TimeInterval)? {
        guard let text = defaults?.string(forKey: questionKey), !text.isEmpty else { return nil }
        let ts = defaults?.double(forKey: questionTimeKey) ?? 0
        return (text, ts)
    }

    static func writeStatus(_ status: String) {
        defaults?.set(status, forKey: statusKey)
    }

    static func readStatus() -> String {
        defaults?.string(forKey: statusKey) ?? "等待屏幕内容..."
    }
}

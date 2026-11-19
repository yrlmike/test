import Foundation

enum AppGroup {
    // ⚠️ 务必修改为你自己在 Xcode Signing & Capabilities 里填写的 App Group ID
    static let id = "group.com.screensolver.shared"
    
    static let darwinNotificationName = "com.screensolver.newQuestion"
    
    private static let questionKey = "latest_question"
    private static let questionTimeKey = "latest_question_ts"
    private static let answerKey = "latest_answer"
    private static let statusKey = "solver_status"

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
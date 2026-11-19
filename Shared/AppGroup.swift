import Foundation
import Security

enum AppGroup {
    static let darwinNotificationName = "com.screensolver.newQuestion"
    private static let questionKey = "latest_question"
    private static let questionTimeKey = "latest_question_ts"

    // 自动探测当前签名实际拥有的第一个 App Group ID，探测不到则回退默认值
    static let id: String = {
        if let task = SecTaskCreateFromSelf(nil),
           let val = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
           let first = val.first, !first.isEmpty {
            return first
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
}

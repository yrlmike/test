import Foundation
import SwiftUI

@MainActor
final class SolverViewModel: ObservableObject {
    static let shared = SolverViewModel()

    @Published var recognizedQuestion: String = ""
    @Published var answerText: String = "等待识别屏幕题目..."
    @Published var isThinking: Bool = false

    // 引擎设置（自动持久化到 UserDefaults）
    @AppStorage("useLocalMLX") var useLocalMLX: Bool = false
    @AppStorage("selectedLocalModel") var selectedLocalModelRaw: String = LocalLLMService.AvailableModel.qwen1_5B.rawValue
    @AppStorage("apiBaseURL") var apiBaseURL: String = "https://api.deepseek.com/v1"
    @AppStorage("apiKey") var apiKey: String = ""
    @AppStorage("apiModelName") var apiModelName: String = "deepseek-chat"

    @Published var modelDownloadProgress: Double = 0.0
    @Published var isDownloadingModel: Bool = false

    private var lastHandledTimestamp: TimeInterval = 0
    private var currentTask: Task<Void, Never>?

    var selectedLocalModel: LocalLLMService.AvailableModel {
        get { LocalLLMService.AvailableModel(rawValue: selectedLocalModelRaw) ?? .qwen1_5B }
        set { selectedLocalModelRaw = newValue.rawValue }
    }

    private init() {
        registerDarwinObserver()
    }

    private func registerDarwinObserver() {
        let name = AppGroup.darwinNotificationName as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    SolverViewModel.shared.handleNewQuestionFromExtension()
                }
            },
            name,
            nil,
            .deliverImmediately
        )
    }

    func handleNewQuestionFromExtension() {
        guard let item = AppGroup.readQuestion() else { return }
        guard item.timestamp > lastHandledTimestamp else { return }
        lastHandledTimestamp = item.timestamp

        recognizedQuestion = item.text
        solve(question: item.text)
    }

    func preloadLocalModel() {
        isDownloadingModel = true
        modelDownloadProgress = 0.0
        answerText = "正在加载/下载本地 MLX 模型..."
        PiPManager.shared.updateText(answerText)

        Task {
            do {
                try await LocalLLMService.shared.loadModel(selectedLocalModel) { progress in
                    Task { @MainActor in
                        self.modelDownloadProgress = progress
                    }
                }
                self.isDownloadingModel = false
                self.answerText = "本地模型 \(selectedLocalModel.displayName) 已就绪！"
                PiPManager.shared.updateText(self.answerText)
            } catch {
                self.isDownloadingModel = false
                self.answerText = "模型加载失败: \(error.localizedDescription)"
                PiPManager.shared.updateText(self.answerText)
            }
        }
    }

    func solve(question: String) {
        currentTask?.cancel()
        isThinking = true
        let loadingHint = "⏳ 正在思考...\n\n识别内容：\n\(question.prefix(60))..."
        answerText = loadingHint
        PiPManager.shared.updateText(loadingHint)

        currentTask = Task {
            do {
                let result: String
                if useLocalMLX || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // 走本地 MLX 离线推理
                    result = try await LocalLLMService.shared.answer(
                        question: question,
                        model: selectedLocalModel
                    ) { progress in
                        Task { @MainActor in
                            if progress < 1.0 {
                                self.isDownloadingModel = true
                                self.modelDownloadProgress = progress
                            } else {
                                self.isDownloadingModel = false
                            }
                        }
                    }
                } else {
                    // 走云端 API
                    let cfg = APIService.Config(
                        baseURL: apiBaseURL,
                        apiKey: apiKey,
                        modelName: apiModelName
                    )
                    result = try await APIService.shared.ask(question: question, config: cfg)
                }

                guard !Task.isCancelled else { return }
                self.isThinking = false
                self.answerText = result
                PiPManager.shared.updateText(result)
            } catch {
                guard !Task.isCancelled else { return }
                self.isThinking = false
                let errMsg = "❌ 推理出错: \(error.localizedDescription)"
                self.answerText = errMsg
                PiPManager.shared.updateText(errMsg)
            }
        }
    }
}
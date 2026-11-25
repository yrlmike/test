import Foundation
import SwiftUI
import Network

@MainActor
final class SolverViewModel: ObservableObject {
    static let shared = SolverViewModel()

    @Published var recognizedQuestion: String = ""
    @Published var answerText: String = "等待识别屏幕题目..."
    @Published var isThinking: Bool = false

    @AppStorage("useLocalMLX") var useLocalMLX: Bool = false
    @AppStorage("selectedLocalModel") var selectedLocalModelRaw: String = LocalLLMService.AvailableModel.qwen1_5B.rawValue
    @AppStorage("apiBaseURL") var apiBaseURL: String = "https://tokenhub.tencentmaas.com/v1"
    @AppStorage("apiKey") var apiKey: String = ""
    @AppStorage("apiModelName") var apiModelName: String = "kimi-k3.1-pro"
    
    // ✅ 新增：自定义提示词配置，设定默认值
    @AppStorage("customPrompt") var customPrompt: String = """
    你是一个手机悬浮窗极速答题助手。用户发来的是考试页面文本（同屏可能包含1到3道连续的选择题）。
    请严格遵守以下规则：
    1. 严禁使用任何Markdown符号（不要出现**、*、#、`、-等）。
    2. 按屏幕从上到下的顺序，识别出所有【题干和选项都完整】的题目，逐题输出答案，每题占一行。
    3. 每行严格按此格式：「题干前4~6个核心字：选项字母」（例如：抗酸剂监护：ABCD）。
    4. 屏幕最上方或最下方若有残缺题目，直接忽略。
    5. 绝不要写任何解析，确保3秒内一眼看清所有选项。
    """

    @Published var modelDownloadProgress: Double = 0.0
    @Published var isDownloadingModel: Bool = false

    private var listener: NWListener?
    private var currentTask: Task<Void, Never>?
    private var lastAnswerTime: Date = .distantPast

    var selectedLocalModel: LocalLLMService.AvailableModel {
        get { LocalLLMService.AvailableModel(rawValue: selectedLocalModelRaw) ?? .qwen1_5B }
        set { selectedLocalModelRaw = newValue.rawValue }
    }

    private init() {
        setenv("HF_ENDPOINT", "https://hf-mirror.com", 1)
        startLocalServer()
        if useLocalMLX, LocalLLMService.shared.localCachedDirectory(for: selectedLocalModel) != nil {
            preloadLocalModel()
        }
    }

    private func startLocalServer() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let port = NWEndpoint.Port(rawValue: 45678)!
            let newListener = try NWListener(using: params, on: port)

            newListener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    guard let data = data,
                          let rawString = String(data: data, encoding: .utf8) else {
                        connection.cancel()
                        return
                    }

                    let parts = rawString.components(separatedBy: "\r\n\r\n")
                    let bodyText = (parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    guard !bodyText.isEmpty else {
                        connection.cancel()
                        return
                    }

                    Task { @MainActor in
                        let vm = SolverViewModel.shared
                        let now = Date()
                        
                        if vm.isThinking || now.timeIntervalSince(vm.lastAnswerTime) < 5.0 {
                            let response = "HTTP/1.1 429 Too Many Requests\r\n\r\n"
                            connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in 
                                connection.cancel() 
                            }))
                            return
                        }

                        let response = "HTTP/1.1 200 OK\r\n\r\n"
                        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in 
                            connection.cancel() 
                        }))

                        vm.recognizedQuestion = bodyText
                        vm.solve(question: bodyText)
                    }
                }
            }
            newListener.start(queue: .global(qos: .userInitiated))
            self.listener = newListener
        } catch {
            self.answerText = "本地服务启动失败: \(error.localizedDescription)"
        }
    }

    func preloadLocalModel() { /* 保持之前不变 */ }

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
                    result = try await LocalLLMService.shared.answer(
                        question: question,
                        systemPrompt: customPrompt, // ✅ 传入前端自定义指令
                        model: selectedLocalModel
                    ) { progress in
                        Task { @MainActor in
                            self.isDownloadingModel = (progress < 1.0)
                            self.modelDownloadProgress = progress
                        }
                    }
                } else {
                    let cfg = APIService.Config(baseURL: apiBaseURL, apiKey: apiKey, modelName: apiModelName)
                    // ✅ 传入前端自定义指令
                    result = try await APIService.shared.ask(question: question, systemPrompt: customPrompt, config: cfg)
                }

                guard !Task.isCancelled else { return }
                self.isThinking = false
                self.answerText = result
                self.lastAnswerTime = Date()
                PiPManager.shared.updateText(result)
            } catch {
                guard !Task.isCancelled else { return }
                self.isThinking = false
                let errMsg = "❌ 推理出错: \(error.localizedDescription)"
                self.answerText = errMsg
                self.lastAnswerTime = Date()
                PiPManager.shared.updateText(errMsg)
            }
        }
    }
}

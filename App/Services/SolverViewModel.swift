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
    @AppStorage("apiModelName") var apiModelName: String = "deepseek/deepseek-flash"

    @Published var modelDownloadProgress: Double = 0.0
    @Published var isDownloadingModel: Bool = false

    private var listener: NWListener?
    private var currentTask: Task<Void, Never>?
    
    // ✅ 新增：记录上一次出答案的时间，用于实现“停留冷却”
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
            let port = NWEndpoint.Port(rawValue: AppGroup.localPort)!
            let newListener = try NWListener(using: params, on: port)

            newListener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    defer { connection.cancel() }
                    guard let data = data,
                          let rawString = String(data: data, encoding: .utf8) else { return }

                    let parts = rawString.components(separatedBy: "\r\n\r\n")
                    let bodyText = (parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in }))

                    guard !bodyText.isEmpty else { return }
                    Task { @MainActor in
                        let vm = SolverViewModel.shared
                        let now = Date()
                        
                        // ✅ 拦截 1：如果正在思考中，忽略新请求，防止模型被频繁打断
                        guard !vm.isThinking else { return }
                        
                        // ✅ 拦截 2：冷却期（3 秒）。出答案后的 3 秒内无视任何扫描结果，让答案在屏幕上停留
                        guard now.timeIntervalSince(vm.lastAnswerTime) > 3.0 else { return }

                        vm.recognizedQuestion = bodyText
                        vm.solve(question: bodyText)
                    }
                }
            }

            newListener.start(queue: .global(qos: .userInitiated))
            self.listener = newListener
        } catch {
            self.answerText = "本地接收服务启动失败: \(error.localizedDescription)"
        }
    }

    func preloadLocalModel() {
        isDownloadingModel = true
        modelDownloadProgress = 0.0
        answerText = "正在离线载入本地 MLX 模型..."
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
                // ✅ 出答案的瞬间，重置计时器，开启 5 秒冷却停留锁
                self.lastAnswerTime = Date()
                PiPManager.shared.updateText(result)
                
            } catch {
                guard !Task.isCancelled else { return }
                
                self.isThinking = false
                let errMsg = "❌ 推理出错: \(error.localizedDescription)"
                self.answerText = errMsg
                // ✅ 哪怕是报错，也给它停留 5 秒，防止屏幕疯狂闪烁报错
                self.lastAnswerTime = Date()
                PiPManager.shared.updateText(errMsg)
            }
        }
    }
}

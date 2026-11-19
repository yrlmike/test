import Foundation
import SwiftUI
import Network

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

    private var listener: NWListener?
    private var currentTask: Task<Void, Never>?

    var selectedLocalModel: LocalLLMService.AvailableModel {
        get { LocalLLMService.AvailableModel(rawValue: selectedLocalModelRaw) ?? .qwen1_5B }
        set { selectedLocalModelRaw = newValue.rawValue }
    }

    private init() {
        startLocalServer()
    }

    // 启动本地 127.0.0.1:45678 端口接收扩展传来的 OCR 文本
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

                    // 解析 HTTP POST Body（空行 \r\n\r\n 之后即为识别出的题目文本）
                    let parts = rawString.components(separatedBy: "\r\n\r\n")
                    let bodyText = (parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    // 立即回复 200 OK 给扩展，防止扩展连接挂起
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in }))

                    guard !bodyText.isEmpty else { return }
                    Task { @MainActor in
                        SolverViewModel.shared.recognizedQuestion = bodyText
                        SolverViewModel.shared.solve(question: bodyText)
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

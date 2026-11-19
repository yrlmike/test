import Foundation
import MLX
import MLXLLM
import MLXLMCommon

actor LocalLLMService {
    static let shared = LocalLLMService()

    private var modelContainer: ModelContainer?
    private var loadedModelId: String?

    enum AvailableModel: String, CaseIterable, Identifiable {
        case qwen1_5B = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        case qwen3B = "mlx-community/Qwen2.5-3B-Instruct-4bit"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .qwen1_5B: return "Qwen2.5-1.5B (推荐·省内存约1GB)"
            case .qwen3B: return "Qwen2.5-3B (高精·需大内存约2GB)"
            }
        }
    }

    func loadModel(_ model: AvailableModel, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if modelContainer != nil && loadedModelId == model.rawValue {
            onProgress(1.0)
            return
        }

        // 切换模型前释放旧模型内存
        modelContainer = nil
        MLX.GPU.clearCache()

        // 限制 MLX GPU 缓存上限，防止 iOS 后台被杀
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        let config = ModelConfiguration(id: model.rawValue)
        let container = try await LLMModelFactory.shared.loadContainer(configuration: config) { progress in
            onProgress(progress.fractionCompleted)
        }

        self.modelContainer = container
        self.loadedModelId = model.rawValue
    }

    func answer(question: String, model: AvailableModel, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await loadModel(model, onProgress: onProgress)
        guard let container = modelContainer else {
            throw NSError(domain: "LocalLLM", code: -1, userInfo: [NSLocalizedDescriptionKey: "本地模型未加载"])
        }

        let prompt = """
        你是屏幕答题助手。忽略界面无关文字，直接给出核心答案，并用不超过3行简要解析。
        屏幕内容：
        \(question)
        """

        let result = try await container.perform { context in
            let input = try await context.processor.prepare(input: .init(prompt: prompt))
            return try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 300, temperature: 0.2, topP: 0.9),
                context: context
            ) { _ in
                .more
            }
        }

        MLX.GPU.clearCache()
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
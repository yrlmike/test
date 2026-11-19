import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Hub

actor LocalLLMService {
    static let shared = LocalLLMService()

    enum AvailableModel: String, CaseIterable, Identifiable {
        case qwen1_5B = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        case qwen3B = "mlx-community/Qwen2.5-3B-Instruct-4bit"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .qwen1_5B: return "Qwen2.5-1.5B (极速版 ~900MB)"
            case .qwen3B: return "Qwen2.5-3B (高精版 ~1.8GB)"
            }
        }
    }

    private var loadedContainer: ModelContainer?
    private var loadedModelID: String?

    /// 检查本地缓存中是否已完整下载过模型文件（含 config.json 与 safetensors 权重）
    nonisolated func localCachedDirectory(for model: AvailableModel) -> URL? {
        let fm = FileManager.default
        let searchRoots = [
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first
        ].compactMap { $0 }

        let repoFolderName = "models--" + model.rawValue.replacingOccurrences(of: "/", with: "--")

        for root in searchRoots {
            // 路径形态 1：Hub 默认缓存结构 .../huggingface/hub/models--mlx-community--.../snapshots/<hash>/
            let snapshotsDir = root
                .appendingPathComponent("huggingface/hub")
                .appendingPathComponent(repoFolderName)
                .appendingPathComponent("snapshots")

            if let hashes = try? fm.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil) {
                for dir in hashes {
                    let configExists = fm.fileExists(atPath: dir.appendingPathComponent("config.json").path)
                    let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                    let hasWeights = files.contains { $0.hasSuffix(".safetensors") }
                    if configExists && hasWeights {
                        return dir
                    }
                }
            }

            // 路径形态 2：直接按 repo id 存放的目录 .../huggingface/models/mlx-community/Qwen...
            let directDir = root
                .appendingPathComponent("huggingface/models")
                .appendingPathComponent(model.rawValue)
            if fm.fileExists(atPath: directDir.appendingPathComponent("config.json").path) {
                return directDir
            }
        }
        return nil
    }

    func loadModel(_ model: AvailableModel, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if loadedModelID == model.rawValue, loadedContainer != nil {
            onProgress(1.0)
            return
        }

        // 限制 MLX GPU 缓存上限，防止后台运行被 iOS Jetsam 杀掉
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        let configuration: ModelConfiguration
        if let localDir = localCachedDirectory(for: model) {
            // ✅ 本地已存在完整权重：直接传入本地目录 URL，0 网络请求、无需 VPN 秒加载
            configuration = ModelConfiguration(directory: localDir)
            onProgress(0.5)
        } else {
            // 首次下载：使用镜像站环境变量拉取
            configuration = ModelConfiguration(id: model.rawValue)
        }

        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration
        ) { progress in
            onProgress(progress.fractionCompleted)
        }

        self.loadedContainer = container
        self.loadedModelID = model.rawValue
        onProgress(1.0)
    }

    func answer(question: String, model: AvailableModel, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await loadModel(model, onProgress: onProgress)
        guard let container = loadedContainer else {
            throw NSError(domain: "LocalLLM", code: -1, userInfo: [NSLocalizedDescriptionKey: "模型未就绪"])
        }

        let systemPrompt = """
        你是一个手机悬浮窗极速答题助手。根据识别出的题目文本直接给出纯文本答案：
        1. 严禁使用任何 Markdown 格式符号（不要出现 **、*、#、`、- 等符号）。
        2. 第一行直接给出最终核心答案（如选项字母、计算结果或核心定义），独占一行。
        3. 第二行起用不超过 2 句话简明解释，总字数控制在 70 字以内，不要任何客套话或重复题目。
        """

        let result = try await container.perform { context in
            let input = try await context.processor.prepare(
                input: .init(messages: [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": question]
                ])
            )
            let params = GenerateParameters(maxTokens: 160, temperature: 0.2)
            return try MLXLMCommon.generate(input: input, parameters: params, context: context) { tokens in
                return tokens.count >= 160 ? .stop : .more
            }
        }

        let cleaned = result.output
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "未能生成有效答案" : cleaned
    }
}

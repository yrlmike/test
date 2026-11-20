import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// 实时监听大文件下载字节进度的代理类
private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws -> (URL, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(max(fraction, 0.0), 1.0))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 必须同步把临时文件移走，否则代理方法返回后系统会立即删除 location
        let fm = FileManager.default
        let safeTemp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try fm.moveItem(at: location, to: safeTemp)
            guard let response = downloadTask.response else {
                continuation?.resume(throwing: URLError(.badServerResponse))
                continuation = nil
                return
            }
            continuation?.resume(returning: (safeTemp, response))
            continuation = nil
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
            session.finishTasksAndInvalidate()
        }
    }
}

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

        var requiredFiles: [String] {
            [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "model.safetensors"
            ]
        }
    }

    private var loadedContainer: ModelContainer?
    private var loadedModelID: String?

    /// 专用的持久化本地模型目录：Documents/MLXModels/<模型文件夹>
    nonisolated func dedicatedModelDirectory(for model: AvailableModel) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folderName = model.rawValue.replacingOccurrences(of: "/", with: "_")
        return docs.appendingPathComponent("MLXModels").appendingPathComponent(folderName)
    }

    /// 严格校验本地模型是否完整（必须包含 config.json、tokenizer.json 且权重文件 > 500MB）
    nonisolated func localCachedDirectory(for model: AvailableModel) -> URL? {
        let fm = FileManager.default
        let candidateDirs = [
            dedicatedModelDirectory(for: model),
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("huggingface/models")
                .appendingPathComponent(model.rawValue)
        ].compactMap { $0 }

        for dir in candidateDirs {
            if isDirectoryValid(dir) {
                return dir
            }
        }

        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let repoFolder = "models--" + model.rawValue.replacingOccurrences(of: "/", with: "--")
            let snapshots = caches.appendingPathComponent("huggingface/hub/\(repoFolder)/snapshots")
            if let hashes = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) {
                for dir in hashes where isDirectoryValid(dir) {
                    return dir
                }
            }
        }
        return nil
    }

    nonisolated private func isDirectoryValid(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let configOK = fm.fileExists(atPath: dir.appendingPathComponent("config.json").path)
        let tokenizerOK = fm.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path)
        guard configOK && tokenizerOK else { return false }

        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return false
        }
        var totalWeightBytes: Int64 = 0
        for file in files where file.pathExtension == "safetensors" {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalWeightBytes += Int64(size)
        }
        return totalWeightBytes > 500 * 1024 * 1024
    }

    /// 绕开 Hub 元数据校验，直接从国内镜像站下载模型文件，并排除 iCloud 备份 + 按字节刷新进度条
    private func downloadModelDirectly(_ model: AvailableModel, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let rootModelsDir = docs.appendingPathComponent("MLXModels")
        let targetDir = dedicatedModelDirectory(for: model)

        if fm.fileExists(atPath: targetDir.path) {
            try? fm.removeItem(at: targetDir)
        }
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // ✅ 标记整个 MLXModels 目录排除在 iCloud 备份之外，不占用云盘空间
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableRoot = rootModelsDir
        var mutableTarget = targetDir
        try? mutableRoot.setResourceValues(resourceValues)
        try? mutableTarget.setResourceValues(resourceValues)

        let mirrorBase = "https://hf-mirror.com/\(model.rawValue)/resolve/main"
        let files = model.requiredFiles

        for (index, fileName) in files.enumerated() {
            guard let fileURL = URL(string: "\(mirrorBase)/\(fileName)") else { continue }
            let destURL = targetDir.appendingPathComponent(fileName)

            let (tempURL, response): (URL, URLResponse)
            if fileName.hasSuffix(".safetensors") {
                // ✅ 大权重文件使用带字节进度的下载器，平滑映射 5% -> 90% 区间
                let downloader = FileDownloadDelegate { fileFraction in
                    let mappedProgress = 0.05 + fileFraction * 0.85
                    onProgress(mappedProgress)
                }
                (tempURL, response) = try await downloader.download(from: fileURL)
            } else {
                // 小配置文件直接下载，占前 5% 进度
                (tempURL, response) = try await URLSession.shared.download(from: fileURL)
                let smallStep = Double(index + 1) / 3.0 * 0.05
                onProgress(min(smallStep, 0.05))
            }

            if let httpResp = response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
                try? fm.removeItem(at: tempURL)
                throw NSError(
                    domain: "LocalLLM",
                    code: httpResp.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "下载 \(fileName) 失败 (HTTP \(httpResp.statusCode))"]
                )
            }
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: tempURL, to: destURL)
        }

        return targetDir
    }

    func loadModel(_ model: AvailableModel, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if loadedModelID == model.rawValue, loadedContainer != nil {
            onProgress(1.0)
            return
        }

        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        let localDir: URL
        if let cached = localCachedDirectory(for: model) {
            localDir = cached
            onProgress(0.6)
        } else {
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: caches.appendingPathComponent("huggingface"))
            }
            localDir = try await downloadModelDirectly(model, onProgress: onProgress)
        }

        let configuration = ModelConfiguration(directory: localDir)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration
        ) { progress in
            onProgress(0.9 + progress.fractionCompleted * 0.1)
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

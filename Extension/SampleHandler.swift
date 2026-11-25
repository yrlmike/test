import ReplayKit
import Vision
import CoreImage

class SampleHandler: RPBroadcastSampleHandler {

    private var lastProcessTime: TimeInterval = 0
    private var lastSentText: String = ""
    private let ciContext = CIContext(options: nil)
    private let ocrQueue = DispatchQueue(label: "com.screensolver.ocr", qos: .userInitiated)
    private var isProcessing = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        lastSentText = ""
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = Date().timeIntervalSince1970
        guard now - lastProcessTime >= 1.5, !isProcessing else { return }
        lastProcessTime = now
        isProcessing = true

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            isProcessing = false
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = ciImage.extent.width
        let scale = width > 1080 ? (1080.0 / width) : 1.0
        let scaledImage = scale < 1.0 ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ciImage

        guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            isProcessing = false
            return
        }

        ocrQueue.async { [weak self] in
            defer { self?.isProcessing = false }
            self?.performOCR(on: cgImage)
        }
    }

    private func performOCR(on cgImage: CGImage) {
        let request = VNRecognizeTextRequest { [weak self] req, err in
            guard let self = self,
                  err == nil,
                  let observations = req.results as? [VNRecognizedTextObservation] else { return }

            // ✅ 步骤 1：按照 Y 轴从上到下初步排序 (midY 越大越靠屏幕上方)
            let sortedObs = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

            // 拦截画中画自带提示音，防止自循环
            if sortedObs.compactMap({ $0.topCandidates(1).first?.string }).contains(where: { $0.contains("正在思考") }) {
                return
            }

            // ✅ 步骤 2：核心修复 —— 二维聚类重组 (Y轴容差成行，X轴横向排序)
            var lines: [[VNRecognizedTextObservation]] = []
            let yTolerance: CGFloat = 0.015 // 容许 1.5% 屏幕高度的误差，将由于排版错开的一排选项合并为同一行

            for obs in sortedObs {
                if lines.isEmpty {
                    lines.append([obs])
                } else {
                    let lastLineIndex = lines.count - 1
                    if let anchor = lines[lastLineIndex].first, abs(anchor.boundingBox.midY - obs.boundingBox.midY) <= yTolerance {
                        // 属于同一行，塞进最后一个数组
                        lines[lastLineIndex].append(obs)
                    } else {
                        // 换新行
                        lines.append([obs])
                    }
                }
            }

            // ✅ 步骤 3：每一行内部按 X 轴从左到右排序，并用空格拼起来 (解决 A. 与 华法林 断裂问题)
            var rawLines: [String] = []
            for line in lines {
                let sortedLine = line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                let lineText = sortedLine.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                rawLines.append(lineText)
            }

            // 过滤无用杂音
            let ignoredSubstrings = [
                "等待识别屏幕题目", "识别内容：", "本地模型", "已就绪",
                "正在离线载入", "推理出错", "Qwen2.5", "ks.wjx.com", "三基考试"
            ]
            let cleanLines = rawLines.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "提交" || trimmed == "上一页" || trimmed == "下一页" { return false }
                return !ignoredSubstrings.contains(where: { trimmed.contains($0) })
            }

            let fullText = cleanLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard fullText.count >= 6 else { return }

            if self.isSimilar(fullText, to: self.lastSentText) {
                return
            }

            self.sendToHostApp(text: fullText)
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        // 裁掉屏幕最顶部12% (状态栏和网页标题)，只扫中间及下方题目区域
        request.regionOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.88)

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
    }

    private func isSimilar(_ a: String, to b: String) -> Bool {
        if b.isEmpty { return false }
        if a == b { return true }
        let setA = Set(a)
        let setB = Set(b)
        let intersection = setA.intersection(setB).count
        let union = max(setA.union(setB).count, 1)
        return Double(intersection) / Double(union) > 0.78
    }

    private func sendToHostApp(text: String) {
        guard let url = URL(string: "http://127.0.0.1:45678") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.0
        request.httpBody = text.data(using: .utf8)

        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                self?.lastSentText = text
            }
        }
        task.resume()
    }
}

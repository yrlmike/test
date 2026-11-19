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
        AppGroup.writeStatus("录屏已开启，正在监测屏幕...")
    }

    override func broadcastFinished() {
        AppGroup.writeStatus("录屏已结束")
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

            // 如果悬浮窗正处于“正在思考”阶段，暂缓新采样，避免打断当前推理
            let rawLines = observations
                .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                .compactMap { $0.topCandidates(1).first?.string }

            if rawLines.contains(where: { $0.contains("正在思考") }) {
                return
            }

            // 逐行剔除悬浮窗自身的状态提示行，只保留真实的题目内容
            let ignoredSubstrings = [
                "等待识别屏幕题目",
                "识别内容：",
                "本地模型",
                "已就绪",
                "正在离线载入",
                "推理出错",
                "Qwen2.5"
            ]
            let cleanLines = rawLines.filter { line in
                !ignoredSubstrings.contains(where: { line.contains($0) })
            }

            let fullText = cleanLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            // 过滤掉无意义的短字符
            guard fullText.count >= 3 else { return }

            // 防抖去重：若题目内容未变化，不重复触发
            if self.isSimilar(fullText, to: self.lastSentText) {
                return
            }

            self.lastSentText = fullText
            AppGroup.writeQuestion(fullText)
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        request.regionOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.935)

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
        return Double(intersection) / Double(union) > 0.85
    }
}

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

            let rawLines = observations
                .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                .compactMap { $0.topCandidates(1).first?.string }

            if rawLines.contains(where: { $0.contains("正在思考") }) {
                return
            }

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
            guard fullText.count >= 3 else { return }

            if self.isSimilar(fullText, to: self.lastSentText) {
                return
            }

            // 发送给本地主 App
            self.sendToHostApp(text: fullText)
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

    private func sendToHostApp(text: String) {
        guard let url = URL(string: "http://127.0.0.1:45678") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.0
        request.httpBody = text.data(using: .utf8)
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            // 核心修复：只有主 App 处理了这道题，才把它写进防抖黑名单
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                self?.lastSentText = text
            }
        }
        task.resume()
    }
}

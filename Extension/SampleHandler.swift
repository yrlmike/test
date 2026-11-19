import ReplayKit
import Vision
import CoreImage

class SampleHandler: RPBroadcastSampleHandler {

    private var lastFrameTime: CFTimeInterval = 0
    private let frameInterval: CFTimeInterval = 1.5
    private let ocrQueue = DispatchQueue(label: "com.screensolver.ocr", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    private var lastRecognizedText: String = ""
    private var isProcessing = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        lastRecognizedText = ""
        AppGroup.writeStatus("录屏已开启，正在监测屏幕...")
    }

    override func broadcastFinished() {
        AppGroup.writeStatus("录屏已结束")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        guard !isProcessing else { return }

        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= frameInterval else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        isProcessing = true

        ocrQueue.async { [weak self] in
            defer { self?.isProcessing = false }
            self?.processFrame(pixelBuffer: pixelBuffer)
        }
    }

    private func processFrame(pixelBuffer: CVPixelBuffer) {
        // 1. 缩放图像至宽度 <= 1080，防止高分屏 OCR 触发 50MB 内存上限崩溃
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = ciImage.extent.width
        let targetWidth: CGFloat = 1080.0
        let scaledImage: CIImage
        if width > targetWidth {
            let scale = targetWidth / width
            scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaledImage = ciImage
        }

        // 2. 配置 Vision OCR
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self = self,
                  error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else { return }

            // 按屏幕从上到下排序（Vision 坐标系原点在左下角，故 y 越大越靠上）
            let sorted = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
            let fullText = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            // 过滤过短的无效界面杂音
            guard fullText.count >= 6 else { return }

            // 3. 文本相似度去重：防止静止画面重复触发大模型推理
            guard !self.isSimilar(text1: fullText, text2: self.lastRecognizedText) else { return }
            self.lastRecognizedText = fullText

            // 4. 写入 App Group 并唤醒主 App
            AppGroup.writeQuestion(fullText)
            self.postDarwinNotification()
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(ciImage: scaledImage, options: [:])
        try? handler.perform([request])
    }

    private func isSimilar(text1: String, text2: String) -> Bool {
        if text1 == text2 { return true }
        if text2.isEmpty { return false }
        let set1 = Set(text1)
        let set2 = Set(text2)
        let intersection = set1.intersection(set2).count
        let union = set1.union(set2).count
        guard union > 0 else { return false }
        // 字符重合度超过 85% 视为同一道题/同一画面
        return Double(intersection) / Double(union) > 0.85
    }

    private func postDarwinNotification() {
        let name = AppGroup.darwinNotificationName as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil,
            nil,
            true
        )
    }
}
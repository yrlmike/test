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
        // 每 1.5 秒采样一次，避免后台 CPU/内存过载
        guard now - lastProcessTime >= 1.5, !isProcessing else { return }
        lastProcessTime = now
        isProcessing = true

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            isProcessing = false
            return
        }

        // 缩放至宽度 <= 1080px 保证速度与识别率
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

            // 按屏幕从上到下排序（Vision 坐标系原点在左下角，boundingBox.midY 越大越靠上）
            let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
            let fullText = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            // 过滤掉无意义的短字符
            guard fullText.count >= 4 else { return }

            // 【优化 2】过滤画中画悬浮窗自身渲染的状态与答案文本，彻底防止“自己识别自己”循环触发
            let selfKeywords = ["等待识别屏幕题目", "正在思考", "识别内容：", "本地模型", "推理出错"]
            if selfKeywords.contains(where: { fullText.contains($0) }) {
                return
            }

            // 防抖去重：若屏幕文字与上次发送高度相似，则不重复触发推理
            if self.isSimilar(fullText, to: self.lastSentText) {
                return
            }

            self.lastSentText = fullText
            AppGroup.writeQuestion(fullText)
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        // 【优化 1】裁掉屏幕最顶部 6.5% 的状态栏区域（Vision 坐标系左下角为 (0,0)，高度设为 0.935 即可避开时间、信号与电量）
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

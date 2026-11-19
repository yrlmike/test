import AVKit
import AVFoundation
import UIKit
import SwiftUI

final class PiPManager: NSObject, ObservableObject {
    static let shared = PiPManager()

    @Published var isPiPActive = false
    @Published var statusMessage = "PiP 未启动"

    let displayLayer = AVSampleBufferDisplayLayer()
    private var pipController: AVPictureInPictureController?
    private var heartbeatTimer: Timer?
    private var currentText: String = "等待识别屏幕题目..."

    private override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    func setupAudioAndPiP() {
        // 1. 激活混合播放音频会话（后台维持 PiP 存活的关键）
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            statusMessage = "音频会话失败: \(error.localizedDescription)"
        }

        // 2. 初始化 PiP 控制器
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            statusMessage = "当前设备不支持画中画"
            return
        }

        if pipController == nil {
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: contentSource)
            controller.delegate = self
            // 隐藏快进快退按钮，界面更干净
            controller.requiresLinearPlayback = true
            self.pipController = controller
        }

        // 预渲染首帧，防止启动 PiP 时黑屏
        pushFrame(text: currentText)
    }

    func startPiP() {
        setupAudioAndPiP()
        pushFrame(text: currentText)

        // 延迟 0.15s 确保首帧已进入解码队列后再拉起画中画
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            if self.pipController?.isPictureInPictureActive == false {
                self.pipController?.startPictureInPicture()
            }
        }
    }

    func stopPiP() {
        pipController?.stopPictureInPicture()
        stopHeartbeat()
    }

    func updateText(_ text: String) {
        currentText = text
        pushFrame(text: text)
    }

    private func startHeartbeat() {
        stopHeartbeat()
        // 1fps 低功耗维持帧缓冲活跃
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pushFrame(text: self.currentText)
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func pushFrame(text: String) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        guard let pixelBuffer = makeTextPixelBuffer(text: text),
              let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else { return }
        displayLayer.enqueue(sampleBuffer)
    }

    private func makeTextPixelBuffer(text: String) -> CVPixelBuffer? {
        // 宽屏比例最适合 iPhone 悬浮窗阅读
        let size = CGSize(width: 960, height: 540)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            // 深色半透明质感背景
            UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // 顶部状态栏装饰条
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 8))

            // 自动根据字数微调字号，保证小窗看得清
            let fontSize: CGFloat = text.count > 120 ? 30 : (text.count > 60 ? 36 : 42)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 8
            paragraph.lineBreakMode = .byTruncatingTail

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]

            let textRect = CGRect(x: 36, y: 28, width: size.width - 72, height: size.height - 56)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
        }

        guard let cgImage = image.cgImage else { return nil }

        var pb: CVPixelBuffer?
        let options: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            options as CFDictionary,
            &pb
        )
        guard let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: baseAddress,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return buffer
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard let format = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = true
            self.statusMessage = "画中画运行中"
            self.startHeartbeat()
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = false
            self.statusMessage = "画中画已关闭"
            self.stopHeartbeat()
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async {
            self.isPiPActive = false
            self.statusMessage = "启动失败: \(error.localizedDescription)"
        }
    }
}

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - 必须挂载到 SwiftUI 视图层级中的宿主 View
struct PiPHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> LayerContainerView {
        let view = LayerContainerView()
        view.backgroundColor = .clear
        let layer = PiPManager.shared.displayLayer
        view.layer.addSublayer(layer)
        view.hostedLayer = layer
        return view
    }

    func updateUIView(_ uiView: LayerContainerView, context: Context) {}

    final class LayerContainerView: UIView {
        weak var hostedLayer: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            hostedLayer?.frame = bounds
        }
    }
}
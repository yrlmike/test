import AVKit
import AVFoundation
import UIKit
import SwiftUI

final class PiPManager: NSObject, ObservableObject {
    static let shared = PiPManager()

    @Published var isPiPActive = false
    @Published var statusMessage = "PiP 未启动"

    let player = AVPlayer()
    let playerLayer = AVPlayerLayer()
    private var pipController: AVPictureInPictureController?
    private var loopObserver: Any?
    private var currentText: String = "等待识别屏幕题目..."
    private var renderCounter: Int = 0

    private override init() {
        super.init()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        player.isMuted = true
    }

    func setupAudioAndPiP() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            statusMessage = "音频会话失败: \(error.localizedDescription)"
        }

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            statusMessage = "当前设备不支持画中画"
            return
        }

        if pipController == nil {
            let controller = AVPictureInPictureController(playerLayer: playerLayer)
            controller?.delegate = self
            controller?.requiresLinearPlayback = true
            self.pipController = controller
        }

        updateText(currentText)
    }

    func startPiP() {
        setupAudioAndPiP()
        player.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            if self.pipController?.isPictureInPictureActive == false {
                self.pipController?.startPictureInPicture()
            }
        }
    }

    func stopPiP() {
        pipController?.stopPictureInPicture()
        player.pause()
    }

    func updateText(_ text: String) {
        currentText = text
        renderCounter += 1
        let index = renderCounter

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self,
                  let videoURL = self.generateTextVideo(text: text, index: index) else { return }

            DispatchQueue.main.async {
                if let observer = self.loopObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                let item = AVPlayerItem(url: videoURL)
                self.player.replaceCurrentItem(with: item)
                self.player.play()

                // 无限循环播放该文字帧视频
                self.loopObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    self?.player.seek(to: .zero)
                    self?.player.play()
                }
            }
        }
    }

    private func generateTextVideo(text: String, index: Int) -> URL? {
        let size = CGSize(width: 960, height: 540)
        let tempDir = FileManager.default.temporaryDirectory
        // 轮流使用两个文件名，防止正在播放时被覆盖
        let fileURL = tempDir.appendingPathComponent("pip_frame_\(index % 2).mp4")
        try? FileManager.default.removeItem(at: fileURL)

        guard let writer = try? AVAssetWriter(outputURL: fileURL, fileType: .mp4) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        guard let buffer = makeTextPixelBuffer(text: text, size: size) else { return nil }

        // 写入 2 帧构成 1 秒视频
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        adaptor.append(buffer, withPresentationTime: .zero)

        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        adaptor.append(buffer, withPresentationTime: CMTime(value: 1, timescale: 1))

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        return writer.status == .completed ? fileURL : nil
    }

    private func makeTextPixelBuffer(text: String, size: CGSize) -> CVPixelBuffer? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 10))

            let fontSize: CGFloat = text.count > 120 ? 32 : (text.count > 60 ? 38 : 46)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 10
            paragraph.lineBreakMode = .byTruncatingTail

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]

            let textRect = CGRect(x: 40, y: 32, width: size.width - 80, height: size.height - 64)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
        }

        guard let cgImage = image.cgImage else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pb
        )
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
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
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = true
            self.statusMessage = "画中画运行中"
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = false
            self.statusMessage = "画中画已关闭"
        }
    }
}

// MARK: - 挂载 AVPlayerLayer 的宿主 View
struct PiPHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> LayerContainerView {
        let view = LayerContainerView()
        view.backgroundColor = .clear
        let layer = PiPManager.shared.playerLayer
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

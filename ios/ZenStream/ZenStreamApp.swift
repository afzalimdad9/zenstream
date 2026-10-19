import AVFoundation
import CoreImage
import CoreText
import SwiftUI
import UIKit

final class CaptureController: NSObject, ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published var micLevel = 0.0
    @Published var cameraStatus = "Camera: waiting for permission"
    @Published var microphoneStatus = "Microphone: waiting for permission"
    @Published var recordingStatus = "Recording: idle"
    @Published var canRecord = false
    @Published var isRecording = false
    @Published var isPortrait = false

    private let sessionQueue = DispatchQueue(label: "com.zenstream.camera")
    private let audioEngine = AVAudioEngine()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var hasStarted = false
    private var audioTapInstalled = false
    private var microphonePermissionGranted = false
    private var videoOutputReady = false
    private var audioOutputReady = false
    private var recordingAudioInput: AVCaptureDeviceInput?
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingSessionStarted = false
    private var recordingFinalizing = false
    private var stopSessionAfterRecording = false
    private var portraitMode = false
    private var outputSize = CGSize(width: 1280, height: 720)
    private var overlayImage: CIImage?
    private var overlayPortraitMode = false
    private var recordingURL: URL?

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.updateCameraStatus("Camera access denied")
                return
            }
            self.sessionQueue.async {
                self.configureCamera()
            }
        }

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.updateMicrophoneStatus("Microphone access denied")
                return
            }
            self.sessionQueue.async {
                self.microphonePermissionGranted = true
                self.updateRecordAvailability()
            }
            self.startMicrophoneMeter()
        }
    }

    func stop() {
        hasStarted = false
        sessionQueue.async {
            if self.assetWriter != nil {
                self.stopSessionAfterRecording = true
                self.stopRecordingOnQueue()
            } else if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        if audioTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioTapInstalled = false
        }
        audioEngine.stop()
    }

    func setPortrait(_ portrait: Bool) {
        sessionQueue.async {
            guard self.assetWriter == nil, self.portraitMode != portrait else { return }
            self.portraitMode = portrait
            self.outputSize = portrait
                ? CGSize(width: 720, height: 1280)
                : CGSize(width: 1280, height: 720)
            self.overlayImage = nil
            DispatchQueue.main.async {
                self.isPortrait = portrait
            }
        }
    }

    var sceneLabel: String {
        isPortrait ? "ZenStream Studio - Vertical 9:16" : "ZenStream Studio - Horizontal 16:9"
    }

    func startRecording() {
        sessionQueue.async {
            guard self.session.isRunning, self.videoOutputReady, self.audioOutputReady,
                  self.microphonePermissionGranted, self.assetWriter == nil else {
                self.updateRecordingStatus("Recording unavailable: capture is not ready")
                return
            }

            self.audioEngine.stop()
            guard self.addRecordingAudioInput() else {
                self.resumeMicrophoneMeter()
                self.updateRecordingStatus("Recording unavailable: microphone input could not be added")
                return
            }

            do {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ZenStream-\(formatter.string(from: Date())).mp4")
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                let width = Int(self.outputSize.width)
                let height = Int(self.outputSize.height)
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: width * height * 4,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                    ]
                ]
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = true
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000
                ]
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true

                guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
                    throw NSError(
                        domain: "ZenStream.Capture",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "MP4 writer inputs could not be configured"]
                    )
                }
                writer.add(videoInput)
                writer.add(audioInput)
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: videoInput,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: width,
                        kCVPixelBufferHeightKey as String: height,
                        kCVPixelBufferCGImageCompatibilityKey as String: true,
                        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
                    ]
                )
                guard writer.startWriting() else {
                    throw writer.error ?? NSError(
                        domain: "ZenStream.Capture",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "MP4 writer could not start"]
                    )
                }

                self.assetWriter = writer
                self.videoWriterInput = videoInput
                self.audioWriterInput = audioInput
                self.pixelBufferAdaptor = adaptor
                self.recordingURL = outputURL
                self.recordingSessionStarted = false
                self.recordingFinalizing = false
                self.updateRecordingStatus("Recording composed output to \(outputURL.path)")
                DispatchQueue.main.async {
                    self.isRecording = true
                }
            } catch {
                self.removeRecordingAudioInput()
                self.resumeMicrophoneMeter()
                self.updateRecordingStatus("Recording failed: \(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        sessionQueue.async {
            self.stopRecordingOnQueue()
        }
    }

    private func stopRecordingOnQueue() {
        guard let writer = assetWriter, !recordingFinalizing else { return }
        recordingFinalizing = true
        updateRecordingStatus("Finalizing MP4 recording...")

        if !recordingSessionStarted {
            writer.cancelWriting()
            completeRecording(with: "Recording stopped before a video frame was captured")
            return
        }

        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.sessionQueue.async {
                if writer.status == .completed, let url = self.recordingURL {
                    self.completeRecording(with: "Recording saved to \(url.path)")
                } else {
                    let message = writer.error?.localizedDescription ?? "MP4 finalization failed"
                    self.completeRecording(with: "Recording failed: \(message)")
                }
            }
        }
    }

    private func completeRecording(with status: String) {
        removeRecordingAudioInput()
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        pixelBufferAdaptor = nil
        recordingURL = nil
        recordingSessionStarted = false
        recordingFinalizing = false
        overlayImage = nil

        if stopSessionAfterRecording {
            session.stopRunning()
            stopSessionAfterRecording = false
        } else if hasStarted {
            resumeMicrophoneMeter()
        }
        updateRecordAvailability()
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingStatus = status
        }
    }

    private func appendVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = assetWriter,
              let input = videoWriterInput,
              let adaptor = pixelBufferAdaptor,
              !recordingFinalizing,
              writer.status == .writing,
              input.isReadyForMoreMediaData,
              let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !recordingSessionStarted {
            writer.startSession(atSourceTime: presentationTime)
            recordingSessionStarted = true
        }

        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        var destinationBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let creationStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &destinationBuffer
        )
        guard creationStatus == kCVReturnSuccess, let destinationBuffer else {
            failRecording("Could not allocate a composed video frame")
            return
        }

        let targetRect = CGRect(origin: .zero, size: outputSize)
        let sourceImage = CIImage(cvPixelBuffer: sourceBuffer)
        let scale = max(
            outputSize.width / sourceImage.extent.width,
            outputSize.height / sourceImage.extent.height
        )
        let scaledImage = sourceImage.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let cropRect = CGRect(
            x: (scaledImage.extent.width - outputSize.width) / 2,
            y: (scaledImage.extent.height - outputSize.height) / 2,
            width: outputSize.width,
            height: outputSize.height
        )
        let croppedImage = scaledImage.cropped(to: cropRect).transformed(
            by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)
        )
        if overlayImage == nil || overlayPortraitMode != portraitMode {
            overlayImage = makeOverlayImage(size: outputSize)
            overlayPortraitMode = portraitMode
        }
        guard let overlayImage else {
            failRecording("Could not create the scene text overlay")
            return
        }
        let composedImage = overlayImage.composited(over: croppedImage)
            .cropped(to: targetRect)
        ciContext.render(
            composedImage,
            to: destinationBuffer,
            bounds: targetRect,
            colorSpace: colorSpace
        )

        if !adaptor.append(destinationBuffer, withPresentationTime: presentationTime) {
            failRecording(writer.error?.localizedDescription ?? "Could not append a composed video frame")
        }
    }

    private func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard !recordingFinalizing, recordingSessionStarted,
              assetWriter?.status == .writing,
              let input = audioWriterInput,
              input.isReadyForMoreMediaData else {
            return
        }
        if !input.append(sampleBuffer) {
            failRecording(assetWriter?.error?.localizedDescription ?? "Could not append microphone audio")
        }
    }

    private func failRecording(_ message: String) {
        assetWriter?.cancelWriting()
        completeRecording(with: "Recording failed: \(message)")
    }

    private func makeOverlayImage(size: CGSize) -> CIImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let margin: CGFloat = 32
        let bannerHeight: CGFloat = 64
        let banner = CGRect(
            x: margin,
            y: size.height - margin - bannerHeight,
            width: size.width - margin * 2,
            height: bannerHeight
        )
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.72))
        context.fill(banner)

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 28, nil)
        let textColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: sceneLabel, attributes: attributes)
        )
        context.textPosition = CGPoint(x: margin + 16, y: size.height - margin - 41)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    private func configureCamera() {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) ?? AVCaptureDevice.default(for: .video) else {
            updateCameraStatus("No camera device found")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .high

            guard session.canAddInput(input) else {
                session.commitConfiguration()
                updateCameraStatus("Camera input could not be added")
                return
            }
            session.addInput(input)

            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                videoOutputReady = true
            }

            audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                audioOutputReady = true
            }
            session.commitConfiguration()

            guard videoOutputReady, audioOutputReady else {
                updateCameraStatus("Camera recording outputs could not be configured")
                return
            }
            session.startRunning()
            updateCameraStatus("Camera preview active")
            updateRecordAvailability()
        } catch {
            updateCameraStatus("Camera unavailable: \(error.localizedDescription)")
        }
    }

    private func addRecordingAudioInput() -> Bool {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            return false
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return false
            }
            session.addInput(input)
            session.commitConfiguration()
            recordingAudioInput = input
            return true
        } catch {
            updateRecordingStatus("Recording failed: \(error.localizedDescription)")
            return false
        }
    }

    private func removeRecordingAudioInput() {
        guard let input = recordingAudioInput else { return }
        session.beginConfiguration()
        session.removeInput(input)
        session.commitConfiguration()
        recordingAudioInput = nil
    }

    private func resumeMicrophoneMeter() {
        guard hasStarted, audioTapInstalled else { return }
        do {
            try audioEngine.start()
            updateMicrophoneStatus("Microphone meter active")
        } catch {
            updateMicrophoneStatus("Microphone unavailable: \(error.localizedDescription)")
        }
    }

    private func startMicrophoneMeter() {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            updateMicrophoneStatus("No microphone input available")
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }

            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0 else { return }

            var sumOfSquares = 0.0
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    let sample = Double(channelData[channel][frame])
                    sumOfSquares += sample * sample
                }
            }
            let sampleCount = Double(frameCount * channelCount)
            let level = min(sqrt(sumOfSquares / sampleCount), 1)
            DispatchQueue.main.async {
                self?.micLevel = level
            }
        }
        audioTapInstalled = true

        do {
            try audioEngine.start()
            updateMicrophoneStatus("Microphone meter active")
        } catch {
            input.removeTap(onBus: 0)
            audioTapInstalled = false
            updateMicrophoneStatus("Microphone unavailable: \(error.localizedDescription)")
        }
    }

    private func updateCameraStatus(_ status: String) {
        DispatchQueue.main.async {
            self.cameraStatus = status
        }
    }

    private func updateMicrophoneStatus(_ status: String) {
        DispatchQueue.main.async {
            self.microphoneStatus = status
        }
    }

    private func updateRecordingStatus(_ status: String) {
        DispatchQueue.main.async {
            self.recordingStatus = status
        }
    }

    private func updateRecordAvailability() {
        let available = hasStarted && session.isRunning && videoOutputReady &&
            audioOutputReady && microphonePermissionGranted && assetWriter == nil &&
            !recordingFinalizing
        DispatchQueue.main.async {
            self.canRecord = available
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            appendVideoFrame(sampleBuffer)
        } else if output === audioOutput {
            appendAudioSample(sampleBuffer)
        }
    }
}

private final class CameraPreviewView: UIView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.addSublayer(previewLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }

    func setSession(_ session: AVCaptureSession) {
        previewLayer.session = session
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewView {
        CameraPreviewView(session: session)
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        view.setSession(session)
    }
}

private struct StudioView: View {
    @StateObject private var capture = CaptureController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("ZenStream Studio")
                    .font(.largeTitle.bold())

                CameraPreview(session: capture.session)
                    .aspectRatio(capture.isPortrait ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .overlay(alignment: .topLeading) {
                        Text(capture.sceneLabel)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(16)
                    }
                    .clipped()
                    .background(.black)

                HStack {
                    Button("Horizontal 16:9") { capture.setPortrait(false) }
                        .disabled(capture.isRecording || !capture.isPortrait)
                    Button("Vertical 9:16") { capture.setPortrait(true) }
                        .disabled(capture.isRecording || capture.isPortrait)
                }
                Text("Microphone level")
                ProgressView(value: capture.micLevel, total: 1)
                Text(capture.cameraStatus)
                    .foregroundStyle(.secondary)
                Text(capture.microphoneStatus)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Record") { capture.startRecording() }
                        .disabled(!capture.canRecord || capture.isRecording)
                    Button("Stop") { capture.stopRecording() }
                        .disabled(!capture.isRecording)
                }
                Text(capture.recordingStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .onAppear { capture.start() }
        .onDisappear { capture.stop() }
    }
}

@main
struct ZenStreamApp: App {
    var body: some Scene {
        WindowGroup {
            StudioView()
        }
    }
}

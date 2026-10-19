import AVFoundation
import AppKit
import SwiftUI

final class CaptureController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    @Published var micLevel = 0.0
    @Published var cameraStatus = "Camera: waiting for permission"
    @Published var microphoneStatus = "Microphone: waiting for permission"
    @Published var recordingStatus = "Recording: idle"
    @Published var canRecord = false
    @Published var isRecording = false

    private let sessionQueue = DispatchQueue(label: "com.zenstream.camera")
    private let audioEngine = AVAudioEngine()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var hasStarted = false
    private var audioTapInstalled = false
    private var microphonePermissionGranted = false
    private var movieOutputReady = false
    private var recordingAudioInput: AVCaptureDeviceInput?
    private var stopSessionAfterRecording = false

    override init() {
        super.init()
    }

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
            if self.movieOutput.isRecording {
                self.stopSessionAfterRecording = true
                self.movieOutput.stopRecording()
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

    func startRecording() {
        sessionQueue.async {
            guard self.session.isRunning, self.movieOutputReady,
                  self.microphonePermissionGranted, !self.movieOutput.isRecording else {
                return
            }

            self.audioEngine.stop()
            guard self.addRecordingAudioInput() else {
                self.resumeMicrophoneMeter()
                self.updateRecordingStatus("Recording unavailable: microphone input could not be added")
                return
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ZenStream-\(formatter.string(from: Date())).mov")
            self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
            self.updateRecordingStatus("Starting recording to \(outputURL.path)")
        }
    }

    func stopRecording() {
        sessionQueue.async {
            guard self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingStatus = "Recording to \(fileURL.path)"
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        sessionQueue.async {
            self.removeRecordingAudioInput()
            if self.hasStarted {
                self.resumeMicrophoneMeter()
            }
            if self.stopSessionAfterRecording {
                self.session.stopRunning()
                self.stopSessionAfterRecording = false
            }

            if let error {
                self.finishRecording(with: "Recording failed: \(error.localizedDescription)")
            } else {
                self.exportRecordingToMP4(from: outputFileURL)
            }
        }
    }

    private func exportRecordingToMP4(from sourceURL: URL) {
        let outputURL = sourceURL.deletingPathExtension().appendingPathExtension("mp4")
        guard let exportSession = AVAssetExportSession(
            asset: AVURLAsset(url: sourceURL),
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            finishRecording(with: "Recording failed: MP4 export could not be created")
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        updateRecordingStatus("Converting recording to MP4...")
        exportSession.exportAsynchronously { [weak self] in
            let status: String
            switch exportSession.status {
            case .completed:
                status = "Recording saved to \(outputURL.path)"
            case .failed:
                status = "MP4 export failed: \(exportSession.error?.localizedDescription ?? "unknown error")"
            case .cancelled:
                status = "MP4 export was cancelled"
            default:
                status = "MP4 export did not complete (status: \(exportSession.status.rawValue))"
            }
            self?.finishRecording(with: status)
        }
    }

    private func finishRecording(with status: String) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingStatus = status
        }
    }

    private func configureCamera() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            updateCameraStatus("No camera device found")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()

            guard session.canAddInput(input) else {
                session.commitConfiguration()
                updateCameraStatus("Camera input could not be added")
                return
            }
            session.addInput(input)
            guard session.canAddOutput(movieOutput) else {
                session.commitConfiguration()
                updateCameraStatus("Camera recording output could not be added")
                return
            }
            session.addOutput(movieOutput)
            movieOutputReady = true
            session.sessionPreset = .high
            session.commitConfiguration()
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
        let available = hasStarted && session.isRunning &&
            movieOutputReady && microphonePermissionGranted
        DispatchQueue.main.async {
            self.canRecord = available
        }
    }
}

private final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = previewLayer
        previewLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = previewLayer
        previewLayer.videoGravity = .resizeAspect
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView(frame: .zero)
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: CameraPreviewNSView, context: Context) {
        view.previewLayer.session = session
    }
}

private struct StudioView: View {
    @StateObject private var capture = CaptureController()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ZenStream Studio")
                .font(.largeTitle.bold())

            CameraPreview(session: capture.session)
                .frame(minHeight: 280)
                .background(.black)

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
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 480)
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

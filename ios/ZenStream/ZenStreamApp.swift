import AVFoundation
import SwiftUI
import UIKit

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

            do {
                guard let documentsDirectory = FileManager.default.urls(
                    for: .documentDirectory,
                    in: .userDomainMask
                ).first else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let directory = documentsDirectory.appendingPathComponent(
                    "ZenStream",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
                let outputURL = directory
                    .appendingPathComponent("ZenStream-\(formatter.string(from: Date())).mov")
                self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
                self.updateRecordingStatus("Starting recording to \(outputURL.path)")
            } catch {
                self.removeRecordingAudioInput()
                self.resumeMicrophoneMeter()
                self.updateRecordingStatus("Recording failed: \(error.localizedDescription)")
            }
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

            DispatchQueue.main.async {
                self.isRecording = false
                if let error {
                    self.recordingStatus = "Recording failed: \(error.localizedDescription)"
                } else {
                    self.recordingStatus = "Recording saved to \(outputFileURL.path)"
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 16) {
            Text("ZenStream")
                .font(.largeTitle.bold())

            CameraPreview(session: capture.session)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))

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
            Spacer(minLength: 0)
        }
        .padding()
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

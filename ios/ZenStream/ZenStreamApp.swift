import AVFoundation
import SwiftUI
import UIKit

final class CaptureController: ObservableObject {
    let session = AVCaptureSession()
    @Published var micLevel = 0.0
    @Published var cameraStatus = "Camera: waiting for permission"
    @Published var microphoneStatus = "Microphone: waiting for permission"

    private let sessionQueue = DispatchQueue(label: "com.zenstream.camera")
    private let audioEngine = AVAudioEngine()
    private var hasStarted = false
    private var audioTapInstalled = false

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
            self.startMicrophoneMeter()
        }
    }

    func stop() {
        hasStarted = false
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        if audioTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioTapInstalled = false
        }
        audioEngine.stop()
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
            defer { session.commitConfiguration() }

            guard session.canAddInput(input) else {
                updateCameraStatus("Camera input could not be added")
                return
            }
            session.addInput(input)
            session.sessionPreset = .high
            session.startRunning()
            updateCameraStatus("Camera preview active")
        } catch {
            updateCameraStatus("Camera unavailable: \(error.localizedDescription)")
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

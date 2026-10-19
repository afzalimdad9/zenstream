import AVFoundation
import AppKit
import SwiftUI

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
        guard let device = AVCaptureDevice.default(for: .video) else {
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

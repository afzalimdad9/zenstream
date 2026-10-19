import SwiftUI

@main
struct ZenStreamApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("ZenStream Studio").font(.largeTitle.bold())
                Text("Native macOS starter")
                Text("Next: AVFoundation capture, scene composition, local recording, and RTMP streaming.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(32)
            .frame(minWidth: 640, minHeight: 420)
        }
    }
}

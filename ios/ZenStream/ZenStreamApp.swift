import SwiftUI

@main
struct ZenStreamApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("ZenStream").font(.largeTitle.bold())
                Text("Native iOS starter")
                Text("Next: camera/microphone capture, mobile scene controls, and streaming.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

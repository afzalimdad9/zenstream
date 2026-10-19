# ZenStream Native Starter

A native multi-platform starter for a Vidyst-style live production studio.

## Platforms
- Windows: C# / WinUI 3 (.NET)
- Android: Kotlin / Jetpack Compose (Gradle)
- Linux: C++ / Qt 6 / CMake
- macOS: Swift / SwiftUI
- iOS: Swift / SwiftUI

## Current scope
The first capture milestone adds a live camera preview and microphone-level meter to all five native apps. Android waits for both camera and microphone permissions before mounting the studio.

Android records camera and microphone output to `Movies/ZenStream`; Windows records to its local ZenStream recordings folder; Linux records to `~/Videos/ZenStream`; macOS and iOS export MP4 recordings to their temporary directories.

Android, Linux, macOS, and iOS compose a camera layer with a studio label in horizontal or vertical output, including the recorded video. Windows has a native preview label and aspect-ratio toggle, but recording still captures the raw camera feed until its Win2D output path is added. Recorded composition on Windows, RTMP output, multistreaming, remote guests, and unified chat remain future milestones.

## Build automation
Push to `main`, open a pull request, or run **Native builds** manually from GitHub Actions. Platform workflows run on the appropriate hosted runners and upload available build artifacts.

### GitHub setup
1. Extract this ZIP.
2. Create a GitHub repository.
3. Copy these files into the repository and push to `main`.
4. Open **Actions** and run **Native builds**.

## Local prerequisites
- Windows: Visual Studio 2022 with the .NET desktop workload and Windows App SDK support.
- Android: JDK 17+ and Android SDK; open `android/` in Android Studio or build with Gradle.
- Linux: Qt 6 Widgets and Multimedia, GStreamer development libraries and plugins, and CMake.
- macOS/iOS: Xcode on macOS. iOS simulator builds require a macOS runner.

## Release notes
CI builds are development artifacts. Android APKs are debug builds. iOS output is for simulator validation; App Store distribution requires signing, provisioning, and release configuration.

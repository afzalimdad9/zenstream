# ZenStream Native Starter

A native multi-platform starter for a Vidyst-style live production studio.

## Platforms
- Windows: C# / WinUI 3 (.NET)
- Android: Kotlin / Jetpack Compose (Gradle)
- Linux: C++ / Qt 6 / CMake
- macOS: Swift / SwiftUI
- iOS: Swift / SwiftUI

## Current scope
This repository contains minimal native app scaffolds and GitHub Actions workflows for platform build checks. It is not yet a full streaming product: capture, scene composition, encoding, RTMP output, multistreaming, guest rooms, and unified chat are future milestones.

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
- Linux: Qt 6 Widgets and CMake.
- macOS/iOS: Xcode on macOS. iOS simulator builds require a macOS runner.

## Release notes
CI builds are development artifacts. Android APKs are debug builds. iOS output is for simulator validation; App Store distribution requires signing, provisioning, and release configuration.

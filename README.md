# Dashcam (iOS)

Native Swift/SwiftUI iPhone app that records a **rolling video buffer** (default 60 seconds, configurable), supports **front**, **back**, or **both** cameras when hardware allows, and can **export** the buffered window on demand or when a **Core Motion acceleration spike** is detected.

## Requirements

- Xcode 16+ (recommended) with the **full Xcode** app selected (`xcode-select -s /Applications/Xcode.app/Contents/Developer`)
- iOS **17** or later on device or Simulator (camera features require a **physical device** for meaningful testing)

## Open and run

1. Open `Dashcam.xcodeproj`
2. Choose an iPhone run destination
3. Build and run (**⌘R**)

Grant **Camera** access when prompted.

## Where clips are saved

Exports are written under the app’s **Documents/Events** directory as MP4 files (one per camera stream when using both cameras).

**Files app:** `Dashcam/Info.plist` sets **UIFileSharingEnabled** and **LSSupportsOpeningDocumentsInPlace** to `true`, merged with the generated Info.plist. In **Files**, go to **On My iPhone → Dashcam** and open **Events**. Delete the app and reinstall once if an older build did not include these keys.

## Known limitations (v1)

- **Background + Maps**: iOS does not allow invisible background camera use. Use **Float over Maps** (Picture in Picture) on the capture screen: keep the small inline preview visible, then start PiP and switch to Maps. PiP uses the **audio** background mode required by AVKit; the rolling buffer and export still run while PiP is active. Without PiP, expect capture to pause when the app is fully backgrounded.
- **Both cameras** requires `AVCaptureMultiCamSession` support; on unsupported devices the app falls back to the **back** camera and shows a note in Settings.
- **Collision detection** is a simple acceleration-threshold heuristic (not a certified crash sensor). Tune threshold and cooldown in Settings; use **Simulate collision** in **Debug** builds to test export on Simulator.

## Project layout

- `Dashcam/App` — app entry + `DashcamViewModel` orchestration
- `Dashcam/Features` — SwiftUI capture and settings screens
- `Dashcam/Services` — camera session, rolling segment writer, exporter, motion monitor

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

- **Background recording (what it really means on iOS)**: The system does **not** allow a third-party app to capture from the camera invisibly while another app (e.g. Maps) fills the screen. **Continuous recording while you use other apps** requires **Picture in Picture (PiP)** so there is a visible capture surface. Turn on **Auto-start PiP when recording** in Settings if you want PiP to begin as soon as the system says it is ready, or use **Float over Maps** manually. The app also declares **`audio`** background mode for AVKit PiP. If you leave Dashcam without PiP active, expect capture to **pause** when the app is fully backgrounded.
- **Indicators**: The **orange / green status bar dots** are system-controlled (camera / microphone). Apps cannot draw the same red **screen recording** style bar over other apps. Dashcam can show a **Live Activity** (Dynamic Island / Lock Screen) while recording—red styling there is app-controlled—and in-app red “recording” UI when PiP is active.
- **Background + Maps (short)**: Use PiP before switching apps; the rolling buffer and export keep running while PiP is active. **Float over Maps** enables once the inline preview is receiving frames and the system reports PiP as possible.
- **Both cameras** requires `AVCaptureMultiCamSession` support; on unsupported devices the app falls back to the **back** camera and shows a note in Settings.
- **Collision detection** is a simple acceleration-threshold heuristic (not a certified crash sensor). Tune threshold and cooldown in Settings; use **Simulate collision** in **Debug** builds to test export on Simulator.

## Project layout

- `Dashcam/App` — app entry + `DashcamViewModel` orchestration
- `Dashcam/Features` — SwiftUI capture and settings screens
- `Dashcam/LiveActivity` — ActivityKit attributes + recording Live Activity bootstrap
- `Dashcam/Services` — camera session, rolling segment writer, exporter, motion monitor
- `DashcamRecordingLiveActivity` — Widget extension (Live Activity UI for Dynamic Island / Lock Screen)

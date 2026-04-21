import AVFoundation
import Combine
import Foundation
import SwiftUI

enum ExportTrigger: String, Sendable {
    case manualSave
    case collision
}

@MainActor
final class DashcamViewModel: ObservableObject {
    /// `var` so `$viewModel.settings.*` bindings compile in SwiftUI.
    var settings = AppSettings()
    var camera = CameraSessionController()
    let pipBridge = PictureInPictureBridge()

    @Published var isRecording = false
    @Published var isExporting = false
    @Published var exportProgress: Float = 0
    @Published var bannerMessage: String?
    @Published var bannerIsError = false

    private var pipeline: CapturePipeline?
    private let collision = CollisionMonitor()
    private let accelerationLogger = AccelerationDebugLogger()
    private var cancellables = Set<AnyCancellable>()
    private var didAttemptAutoPiPThisRecordingSession = false

    init() {
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        camera.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        pipBridge.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        collision.onSpike = { [weak self] in
            guard let self else { return }
            Task { await self.exportRollingWindow(trigger: .collision) }
        }

        settings.$debugAccelerationLogging
            .sink { [weak self] _ in self?.syncAccelerationDebugLogging() }
            .store(in: &cancellables)

        pipBridge.$isPictureInPicturePossible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] possible in
                guard possible else { return }
                self?.tryAutoStartPiPWhenPossible()
            }
            .store(in: &cancellables)
    }

    private func syncAccelerationDebugLogging() {
        let logging = settings.debugAccelerationLogging && isRecording
        collision.onRawAccelerationSample = nil
        accelerationLogger.updateSession(
            isRecording: isRecording,
            debugEnabled: settings.debugAccelerationLogging
        )
        guard logging else { return }
        let logger = accelerationLogger
        collision.onRawAccelerationSample = { ax, ay, az, magnitude, thresholdG, date in
            logger.appendSample(
                ax: ax,
                ay: ay,
                az: az,
                magnitude: magnitude,
                thresholdG: thresholdG,
                timestamp: date
            )
        }
    }

    func onAppear() {
        pipBridge.cameraModeProvider = { [weak self] in self?.effectiveCameraMode ?? .back }
        pipBridge.onPiPFailureMessage = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.showBanner(message, error: true)
            }
        }
        camera.sampleBufferTee = pipBridge
        applyCameraConfiguration(startSession: true)
    }

    /// Starts PiP when the system says it is possible; otherwise explains why the button had no effect.
    func floatOverMapsTapped() {
        guard pipBridge.isPictureInPictureSupported else {
            showBanner("Picture in Picture is not supported on this device.", error: true)
            return
        }
        guard camera.captureSession != nil else {
            showBanner("Camera is not ready yet.", error: true)
            return
        }
        guard pipBridge.isPictureInPicturePossible else {
            showBanner(
                "Picture in Picture is not ready yet. Wait until the small preview shows live video, then try again.",
                error: false
            )
            return
        }
        pipBridge.startPictureInPictureFromMain()
    }

    /// Call when returning to the foreground after the app was backgrounded while recording without PiP.
    func userReturnedFromForegroundWhileRecordingWithoutPiP() {
        guard isRecording else { return }
        guard !pipBridge.isPictureInPictureActive else { return }
        showBanner(
            "Recording may pause in the background until you start Float over Maps (Picture in Picture). Open Float over Maps when the small preview is live.",
            error: false
        )
    }

    private func tryAutoStartPiPWhenPossible() {
        guard isRecording, settings.autoStartPiPWhenRecording else { return }
        attemptSingleAutoPiPStart()
    }

    private func attemptSingleAutoPiPStart() {
        guard !didAttemptAutoPiPThisRecordingSession else { return }
        guard pipBridge.isPictureInPictureSupported, pipBridge.isPictureInPicturePossible else { return }
        didAttemptAutoPiPThisRecordingSession = true
        pipBridge.startPictureInPictureFromMain()
    }

    func applyCameraConfiguration(startSession: Bool) {
        let mode = effectiveCameraMode
        camera.reconfigure(mode: mode) { [weak self] in
            guard let self, startSession else { return }
            self.camera.start()
        }
    }

    var effectiveCameraMode: CameraMode {
        if settings.cameraMode == .both, !camera.multiCamSupported {
            return .back
        }
        return settings.cameraMode
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !isExporting else {
            showBanner("Please wait for export to finish.", error: true)
            return
        }
        guard camera.captureSession != nil else {
            showBanner(camera.lastError ?? "Camera not ready.", error: true)
            return
        }

        let mode = effectiveCameraMode
        let pipe = CapturePipeline(mode: mode, bufferWindowSeconds: settings.bufferSecondsClamped)
        pipeline = pipe
        camera.sampleBufferConsumer = pipe

        collision.thresholdG = settings.collisionThresholdClamped
        collision.cooldownSeconds = settings.collisionCooldownClamped
        collision.start()

        didAttemptAutoPiPThisRecordingSession = false
        isRecording = true
        syncAccelerationDebugLogging()
        showBanner("Recording with a \(Int(settings.bufferSecondsClamped))s rolling buffer.", error: false)
        tryAutoStartPiPWhenPossible()
        RecordingLiveActivityBootstrap.startIfAvailable()
    }

    func stopRecording() {
        collision.stop()
        camera.sampleBufferConsumer = nil
        pipeline?.discard()
        pipeline = nil
        isRecording = false
        didAttemptAutoPiPThisRecordingSession = false
        syncAccelerationDebugLogging()
        showBanner("Recording stopped.", error: false)
        RecordingLiveActivityBootstrap.endIfAvailable()
    }

    func saveTapped() {
        Task { await exportRollingWindow(trigger: .manualSave) }
    }

    #if DEBUG
    func debugSimulateCollision() {
        collision.simulateSpike()
    }
    #endif

    func exportRollingWindow(trigger: ExportTrigger) async {
        guard isRecording else {
            showBanner("Start recording before saving a clip.", error: true)
            return
        }
        guard pipeline != nil else {
            showBanner("Recorder not active.", error: true)
            return
        }
        guard !isExporting else {
            showBanner("Already exporting.", error: true)
            return
        }

        isExporting = true
        exportProgress = 0

        if trigger == .collision {
            try? await Task.sleep(for: .seconds(3))
            guard isRecording, pipeline != nil else {
                isExporting = false
                showBanner("Recording stopped before the collision clip could be finalized.", error: true)
                return
            }
        }

        guard let pipeline else {
            isExporting = false
            return
        }

        let seconds = settings.bufferSecondsClamped

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pipeline.flushAll {
                pipeline.collectSegmentURLs(seconds: seconds) { map in
                    let box = ExportMapBox(map: map)
                    let progressSink = ExportProgressSink(owner: self)
                    Task.detached(priority: .userInitiated) {
                        do {
                            let outcome = try await runRollingClipExportOffMainActor(
                                map: box.map,
                                trigger: trigger,
                                seconds: seconds,
                                progress: { progressSink.push($0) }
                            )
                            await MainActor.run { [weak self] in
                                guard let self else {
                                    continuation.resume()
                                    return
                                }
                                self.isExporting = false
                                self.exportProgress = outcome.bannerIsError ? 0 : 1
                                self.showBanner(outcome.bannerText, error: outcome.bannerIsError)
                                if outcome.restartCollisionMonitoring {
                                    self.collision.stop()
                                    self.collision.thresholdG = self.settings.collisionThresholdClamped
                                    self.collision.cooldownSeconds = self.settings.collisionCooldownClamped
                                    self.collision.start()
                                }
                                continuation.resume()
                            }
                        } catch {
                            await MainActor.run { [weak self] in
                                self?.isExporting = false
                                self?.showBanner(error.localizedDescription, error: true)
                                continuation.resume()
                            }
                        }
                    }
                }
            }
        }
    }

    private final class ExportProgressSink: @unchecked Sendable {
        weak var owner: DashcamViewModel?
        init(owner: DashcamViewModel) { self.owner = owner }
        func push(_ p: Float) {
            Task { @MainActor [weak owner] in
                owner?.exportProgress = p
            }
        }
    }

    private func showBanner(_ text: String, error: Bool) {
        bannerMessage = text
        bannerIsError = error
    }

    func dismissBanner() {
        bannerMessage = nil
    }
}

// MARK: - Rolling export (off MainActor; avoids starving Fig / gesture during Save)

private struct ExportMapBox: @unchecked Sendable {
    let map: [CameraVideoSource: [URL]]
}

private struct RollingClipExportOutcome: Sendable {
    let outputFilenames: [String]
    let bannerText: String
    let bannerIsError: Bool
    let restartCollisionMonitoring: Bool
}

private func runRollingClipExportOffMainActor(
    map: [CameraVideoSource: [URL]],
    trigger: ExportTrigger,
    seconds: Double,
    progress: @escaping (Float) -> Void
) async throws -> RollingClipExportOutcome {
    guard !map.isEmpty else {
        return RollingClipExportOutcome(
            outputFilenames: [],
            bannerText: "Not enough buffered video yet—record a little longer.",
            bannerIsError: true,
            restartCollisionMonitoring: false
        )
    }

    let eventsRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Events", isDirectory: true)
    try? FileManager.default.createDirectory(at: eventsRoot, withIntermediateDirectories: true)

    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let prefix = "\(trigger.rawValue)_\(stamp)"

    var outputs: [String] = []
    for (source, urls) in map.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        let destination = eventsRoot.appendingPathComponent("\(prefix)_\(source.rawValue).mp4")
        try await ClipExporter.export(videoSegmentURLs: urls, to: destination, progress: progress)
        outputs.append(destination.lastPathComponent)
    }

    let label = trigger == .collision ? "Collision clip saved" : "Clip saved"
    let bannerText = "\(label) (~\(Int(seconds))s): \(outputs.joined(separator: ", "))"
    return RollingClipExportOutcome(
        outputFilenames: outputs,
        bannerText: bannerText,
        bannerIsError: false,
        restartCollisionMonitoring: trigger == .collision
    )
}

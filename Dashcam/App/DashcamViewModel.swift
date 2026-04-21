import AVFoundation
import Combine
import Foundation
import SwiftUI

enum ExportTrigger: String {
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
    private var cancellables = Set<AnyCancellable>()

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
    }

    func onAppear() {
        pipBridge.cameraModeProvider = { [weak self] in self?.effectiveCameraMode ?? .back }
        camera.sampleBufferTee = pipBridge
        applyCameraConfiguration(startSession: true)
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

        isRecording = true
        showBanner("Recording with a \(Int(settings.bufferSecondsClamped))s rolling buffer.", error: false)
    }

    func stopRecording() {
        collision.stop()
        camera.sampleBufferConsumer = nil
        pipeline?.discard()
        pipeline = nil
        isRecording = false
        showBanner("Recording stopped.", error: false)
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
        guard let pipeline else {
            showBanner("Recorder not active.", error: true)
            return
        }
        guard !isExporting else {
            showBanner("Already exporting.", error: true)
            return
        }

        isExporting = true
        exportProgress = 0

        let seconds = settings.bufferSecondsClamped

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pipeline.flushAll {
                pipeline.collectSegmentURLs(seconds: seconds) { map in
                    Task { @MainActor in
                        await self.performExport(map: map, trigger: trigger, seconds: seconds)
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func performExport(
        map: [CameraVideoSource: [URL]],
        trigger: ExportTrigger,
        seconds: Double
    ) async {
        defer { isExporting = false }

        guard !map.isEmpty else {
            showBanner("Not enough buffered video yet—record a little longer.", error: true)
            return
        }

        let eventsRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Events", isDirectory: true)
        try? FileManager.default.createDirectory(at: eventsRoot, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let prefix = "\(trigger.rawValue)_\(stamp)"

        do {
            var outputs: [String] = []
            for (source, urls) in map.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let destination = eventsRoot.appendingPathComponent("\(prefix)_\(source.rawValue).mp4")
                try await ClipExporter.export(videoSegmentURLs: urls, to: destination) { [weak self] p in
                    Task { @MainActor in
                        self?.exportProgress = p
                    }
                }
                outputs.append(destination.lastPathComponent)
            }

            exportProgress = 1
            let label = trigger == .collision ? "Collision clip saved" : "Clip saved"
            showBanner("\(label) (~\(Int(seconds))s): \(outputs.joined(separator: ", "))", error: false)

            if trigger == .collision {
                collision.stop()
                collision.thresholdG = settings.collisionThresholdClamped
                collision.cooldownSeconds = settings.collisionCooldownClamped
                collision.start()
            }
        } catch {
            showBanner(error.localizedDescription, error: true)
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

import AVFoundation
import Combine
import CoreMedia
import Foundation
import UIKit

protocol CameraSampleBufferConsumer: AnyObject {
    func ingest(sampleBuffer: CMSampleBuffer, source: CameraVideoSource)
}

protocol CameraSampleBufferTee: AnyObject {
    func tee(sampleBuffer: CMSampleBuffer, source: CameraVideoSource)
    func sessionDidStop()
}

enum CameraVideoSource: String, Sendable {
    case back
    case front
}

private struct MultiCamBuiltSession {
    let session: AVCaptureMultiCamSession
    let backOutput: AVCaptureVideoDataOutput
    let frontOutput: AVCaptureVideoDataOutput
}

private enum MultiCamBuildError: Error {
    case reason(String)
}

/// Owns capture session (single or multi-cam), preview session reference, and video data outputs for recording.
final class CameraSessionController: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var multiCamSupported = AVCaptureMultiCamSession.isMultiCamSupported

    private(set) var captureSession: AVCaptureSession?

    private var singleSession: AVCaptureSession?
    private var multiSession: AVCaptureMultiCamSession?

    private let videoQueue = DispatchQueue(label: "dashcam.video.capture", qos: .userInitiated)
    private var backVideoOutput: AVCaptureVideoDataOutput?
    private var frontVideoOutput: AVCaptureVideoDataOutput?

    weak var sampleBufferConsumer: CameraSampleBufferConsumer?
    weak var sampleBufferTee: CameraSampleBufferTee?

    /// Set from `PreviewView` so `AVCaptureDevice.RotationCoordinator` can align capture + preview with gravity.
    weak var previewVideoLayer: AVCaptureVideoPreviewLayer?

    var previewMirrored: Bool = false

    private var rotationCoordinators: [AVCaptureDevice.RotationCoordinator] = []
    private var rotationObservations: [NSKeyValueObservation] = []

    /// Bumped on each `reconfigure` so a slow multi-cam build cannot apply after a newer configuration.
    private var configurationGeneration = 0

    private var runtimeErrorObserver: NSObjectProtocol?
    private var isRecoveringFromRuntimeError = false

    func reconfigure(mode: CameraMode, completion: (() -> Void)? = nil) {
        configurationGeneration += 1
        let token = configurationGeneration

        stop()
        lastError = nil

        if mode != .both {
            buildSingleSession(position: mode == .front ? .front : .back)
            DispatchQueue.main.async { completion?() }
            return
        }

        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            lastError = "This device does not support recording from both cameras at once."
            buildSingleSession(position: .back)
            DispatchQueue.main.async { completion?() }
            return
        }

        #if targetEnvironment(simulator)
        lastError = "Dual camera is not supported in the iOS Simulator."
        buildSingleSession(position: .back)
        DispatchQueue.main.async { completion?() }
        return
        #endif

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?() }
                return
            }
            let result = self.buildMultiSessionGraph()
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                if self.configurationGeneration != token {
                    completion?()
                    return
                }
                switch result {
                case .success(let built):
                    self.multiSession = built.session
                    self.singleSession = nil
                    self.captureSession = built.session
                    self.backVideoOutput = built.backOutput
                    self.frontVideoOutput = built.frontOutput
                    self.previewMirrored = false
                    self.lastError = nil
                case .failure(.reason(let message)):
                    self.lastError = message
                    self.buildSingleSession(position: .back)
                }
                completion?()
            }
        }
    }

    private func buildSingleSession(position: AVCaptureDevice.Position) {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            lastError = "Could not open \(position == .front ? "front" : "back") camera."
            captureSession = nil
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = Self.multiCamPixelSettings
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            lastError = "Could not add video output."
            captureSession = nil
            return
        }
        session.addOutput(output)

        session.commitConfiguration()

        singleSession = session
        multiSession = nil
        captureSession = session
        backVideoOutput = position == .back ? output : nil
        frontVideoOutput = position == .front ? output : nil
        previewMirrored = position == .front
    }

    /// Lighter presets first — multi-cam often fails Fig budget at 1080p.
    private func applyMultiCamSessionPreset(_ session: AVCaptureMultiCamSession) {
        let presets: [AVCaptureSession.Preset] = [
            .vga640x480,
            .medium,
            .inputPriority,
            .hd1280x720,
            .hd1920x1080,
        ]
        for preset in presets where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            return
        }
    }

    /// Returns devices plus whether they came from `DiscoverySession.supportedMultiCamDeviceSets` (then skip manual `activeFormat`).
    private func pickMultiCamWideAnglePair() -> (AVCaptureDevice, AVCaptureDevice, Bool)? {
        let discoveryTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryTypes,
            mediaType: .video,
            position: .unspecified
        )
        for deviceSet in discovery.supportedMultiCamDeviceSets {
            let backs = deviceSet.filter { $0.position == AVCaptureDevice.Position.back }
            let fronts = deviceSet.filter { $0.position == AVCaptureDevice.Position.front }
            let back = backs.first { $0.deviceType == .builtInWideAngleCamera } ?? backs.first
            let front = fronts.first { $0.deviceType == .builtInWideAngleCamera } ?? fronts.first
            if let back, let front { return (back, front, true) }
        }
        guard
            let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        else {
            return nil
        }
        return (back, front, false)
    }

    private func firstMultiCamFormat(on device: AVCaptureDevice, width: Int32, height: Int32) -> AVCaptureDevice.Format? {
        device.formats.first { format in
            guard format.isMultiCamSupported else { return false }
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return d.width == width && d.height == height
        }
    }

    private func pickPairedMultiCamFormats(
        back: AVCaptureDevice,
        front: AVCaptureDevice
    ) -> (AVCaptureDevice.Format, AVCaptureDevice.Format)? {
        let preferredSizes: [(Int32, Int32)] = [
            (1280, 720),
            (960, 540),
            (640, 480),
            (1920, 1080),
        ]
        for (w, h) in preferredSizes {
            if let bf = firstMultiCamFormat(on: back, width: w, height: h),
               let ff = firstMultiCamFormat(on: front, width: w, height: h) {
                return (bf, ff)
            }
        }
        return nil
    }

    private func applyPairedMultiCamFormatsIfPossible(back: AVCaptureDevice, front: AVCaptureDevice) {
        guard let (backFormat, frontFormat) = pickPairedMultiCamFormats(back: back, front: front) else { return }
        do {
            try back.lockForConfiguration()
            defer { back.unlockForConfiguration() }
            try front.lockForConfiguration()
            defer { front.unlockForConfiguration() }
            back.activeFormat = backFormat
            front.activeFormat = frontFormat
        } catch {}
    }

    /// Lower peak bandwidth / Fig load for dual `AVCaptureVideoDataOutput` (helps -17281 on some devices).
    private func relaxMultiCamDevicesForFigBudget(back: AVCaptureDevice, front: AVCaptureDevice) {
        let minFrameDuration = CMTime(value: 1, timescale: 15)
        for device in [back, front] {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.activeVideoMinFrameDuration = minFrameDuration
            } catch {}
        }
    }

    private func removeRuntimeErrorObserver() {
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            runtimeErrorObserver = nil
        }
    }

    private func installRuntimeErrorObserver(session: AVCaptureSession) {
        removeRuntimeErrorObserver()
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard !self.isRecoveringFromRuntimeError else { return }
            let errText = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown"
            self.isRecoveringFromRuntimeError = true
            self.lastError = "Dual camera stopped (\(errText)). Using the back camera only."
            self.stop()
            self.buildSingleSession(position: .back)
            self.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isRecoveringFromRuntimeError = false
            }
        }
    }

    private static let multiCamPixelSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    ]

    /// Build graph off the main thread (can be heavy); do not touch `@Published` here.
    private func buildMultiSessionGraph() -> Result<MultiCamBuiltSession, MultiCamBuildError> {
        guard let pick = pickMultiCamWideAnglePair() else {
            return .failure(.reason("Could not find a supported dual-camera device set."))
        }
        let (backDevice, frontDevice, fromSystemSupportedSet) = pick

        if !fromSystemSupportedSet {
            applyPairedMultiCamFormatsIfPossible(back: backDevice, front: frontDevice)
        }
        relaxMultiCamDevicesForFigBudget(back: backDevice, front: frontDevice)

        let backInput: AVCaptureDeviceInput
        let frontInput: AVCaptureDeviceInput
        do {
            backInput = try AVCaptureDeviceInput(device: backDevice)
            frontInput = try AVCaptureDeviceInput(device: frontDevice)
        } catch {
            return .failure(.reason(error.localizedDescription))
        }

        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()

        guard session.canAddInput(backInput), session.canAddInput(frontInput) else {
            session.commitConfiguration()
            return .failure(.reason("Multi-cam inputs could not be added."))
        }
        session.addInputWithNoConnections(backInput)
        session.addInputWithNoConnections(frontInput)

        let backOutput = AVCaptureVideoDataOutput()
        backOutput.alwaysDiscardsLateVideoFrames = true
        backOutput.videoSettings = Self.multiCamPixelSettings
        backOutput.setSampleBufferDelegate(self, queue: videoQueue)

        let frontOutput = AVCaptureVideoDataOutput()
        frontOutput.alwaysDiscardsLateVideoFrames = true
        frontOutput.videoSettings = Self.multiCamPixelSettings
        frontOutput.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(backOutput), session.canAddOutput(frontOutput) else {
            session.commitConfiguration()
            return .failure(.reason("Could not add multi-cam outputs."))
        }
        session.addOutputWithNoConnections(backOutput)
        session.addOutputWithNoConnections(frontOutput)

        let backPort = backInput.ports.first { port in
            port.mediaType == .video
                && port.sourceDeviceType == .builtInWideAngleCamera
        } ?? backInput.ports.first { $0.mediaType == .video }

        let frontPort = frontInput.ports.first { port in
            port.mediaType == .video
                && port.sourceDeviceType == .builtInWideAngleCamera
        } ?? frontInput.ports.first { $0.mediaType == .video }

        guard let bPort = backPort, let fPort = frontPort else {
            session.commitConfiguration()
            return .failure(.reason("Missing video ports for multi-cam."))
        }

        let backConn = AVCaptureConnection(inputPorts: [bPort], output: backOutput)
        let frontConn = AVCaptureConnection(inputPorts: [fPort], output: frontOutput)
        guard session.canAddConnection(backConn), session.canAddConnection(frontConn) else {
            session.commitConfiguration()
            return .failure(.reason("Could not connect multi-cam video outputs."))
        }
        session.addConnection(backConn)
        session.addConnection(frontConn)

        applyMultiCamSessionPreset(session)

        session.commitConfiguration()

        // `hardwareCost` is normalized ~0…1; values above 1.0 mean the graph exceeds the allowed budget.
        if session.hardwareCost > 1.0 {
            return .failure(.reason("Dual camera exceeds the device budget right now."))
        }

        return .success(MultiCamBuiltSession(session: session, backOutput: backOutput, frontOutput: frontOutput))
    }

    /// Call from the main thread when the SwiftUI preview layer is ready (same session as `captureSession`).
    func updatePreviewVideoLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewVideoLayer = layer
        reinstallRotationCoordinatorsIfPossible()
    }

    private func removeRotationCoordinators() {
        rotationObservations.forEach { $0.invalidate() }
        rotationObservations.removeAll()
        rotationCoordinators.removeAll()
    }

    private func reinstallRotationCoordinatorsIfPossible() {
        removeRotationCoordinators()
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reinstallRotationCoordinatorsIfPossible() }
            return
        }
        guard let session = captureSession, let previewLayer = previewVideoLayer else { return }
        guard previewLayer.session === session else { return }

        var coordinators: [AVCaptureDevice.RotationCoordinator] = []

        let kvoOptions: NSKeyValueObservingOptions = [.initial, .new]

        for case let input as AVCaptureDeviceInput in session.inputs where input.device.hasMediaType(.video) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: input.device, previewLayer: previewLayer)
            coordinators.append(coordinator)

            let position = input.device.position
            let captureObs = coordinator.observe(
                \AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelCapture,
                options: kvoOptions
            ) { [weak self] (coord: AVCaptureDevice.RotationCoordinator, change: NSKeyValueObservedChange<CGFloat>) in
                _ = change
                let angle = coord.videoRotationAngleForHorizonLevelCapture
                DispatchQueue.main.async {
                    self?.applyCaptureRotationAngle(angle, devicePosition: position)
                }
            }
            rotationObservations.append(captureObs)
        }

        rotationCoordinators = coordinators

        let coordinatorForBackPreview: AVCaptureDevice.RotationCoordinator? = coordinators
            .filter { rotationCoordinator in
                guard let captureDevice = rotationCoordinator.device else { return false }
                return captureDevice.position == AVCaptureDevice.Position.back
            }
            .first
        let coordinatorForPreviewAngle = coordinatorForBackPreview ?? coordinators.first
        guard let previewCoord = coordinatorForPreviewAngle else { return }

        let previewObs = previewCoord.observe(
            \AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelPreview,
            options: kvoOptions
        ) { [weak self] (coord: AVCaptureDevice.RotationCoordinator, change: NSKeyValueObservedChange<CGFloat>) in
            _ = change
            let angle = coord.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                self?.applyPreviewRotationAngle(angle)
            }
        }
        rotationObservations.append(previewObs)
    }

    private func applyCaptureRotationAngle(_ angle: CGFloat, devicePosition: AVCaptureDevice.Position) {
        let output: AVCaptureVideoDataOutput?
        switch devicePosition {
        case .back:
            output = backVideoOutput
        case .front:
            output = frontVideoOutput
        default:
            output = nil
        }
        guard let output, let connection = output.connection(with: .video) else { return }
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func applyPreviewRotationAngle(_ angle: CGFloat) {
        guard let previewLayer = previewVideoLayer, let connection = previewLayer.connection else { return }
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    func start() {
        guard let session = captureSession else { return }
        // `startRunning` must run on the main thread when using `AVCaptureVideoPreviewLayer`, or Fig can
        // throw remote capture errors (-17281) and stall the main runloop (gesture timeouts).
        DispatchQueue.main.async { [weak self] in
            guard !session.isRunning else {
                self?.isRunning = true
                self?.reinstallRotationCoordinatorsIfPossible()
                return
            }
            session.startRunning()
            self?.installRuntimeErrorObserver(session: session)
            self?.isRunning = session.isRunning
            self?.reinstallRotationCoordinatorsIfPossible()
        }
    }

    func stop() {
        removeRotationCoordinators()
        removeRuntimeErrorObserver()
        backVideoOutput?.setSampleBufferDelegate(nil, queue: nil)
        frontVideoOutput?.setSampleBufferDelegate(nil, queue: nil)

        guard let session = captureSession else {
            isRunning = false
            return
        }

        // Match `startRunning`: stop on the main thread when a preview layer is attached.
        let stopRunningIfNeeded = {
            if session.isRunning {
                session.stopRunning()
            }
        }
        if Thread.isMainThread {
            stopRunningIfNeeded()
        } else {
            DispatchQueue.main.sync(execute: stopRunningIfNeeded)
        }

        sampleBufferTee?.sessionDidStop()

        backVideoOutput = nil
        frontVideoOutput = nil
        singleSession = nil
        multiSession = nil
        captureSession = nil
        isRunning = false
    }
}

extension CameraSessionController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let source: CameraVideoSource
        if let back = backVideoOutput, back === output {
            source = .back
        } else if let front = frontVideoOutput, front === output {
            source = .front
        } else {
            source = .back
        }

        sampleBufferTee?.tee(sampleBuffer: sampleBuffer, source: source)

        guard let consumer = sampleBufferConsumer else { return }
        consumer.ingest(sampleBuffer: sampleBuffer, source: source)
    }
}

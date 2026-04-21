import AVFoundation
import AVKit
import Combine
import CoreMedia
import Foundation

/// Feeds one camera stream into `AVSampleBufferDisplayLayer` and drives PiP so capture can continue over other apps (e.g. Maps).
final class PictureInPictureBridge: NSObject, ObservableObject {
    /// Shown inline and used as the PiP content source (must stay in a view hierarchy while PiP may be active).
    let sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()

    @Published private(set) var isPictureInPictureSupported = false
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var isPictureInPictureActive = false

    /// Match `DashcamViewModel.effectiveCameraMode` for which stream to mirror into PiP.
    var cameraModeProvider: () -> CameraMode = { .back }

    /// Called on the main queue when PiP fails to start (for banners / alerts).
    var onPiPFailureMessage: ((String) -> Void)?

    private var pipController: AVPictureInPictureController?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var pipActiveObservation: NSKeyValueObservation?
    private var prepared = false

    /// Coalesce camera frames onto one pending sample; unbounded `main.async` per frame starves the run loop and the inline layer never draws.
    private let coalesceLock = NSLock()
    private var coalescedLatestSampleBuffer: CMSampleBuffer?
    private var coalescedDrainScheduled = false

    override init() {
        super.init()
        sampleBufferDisplayLayer.videoGravity = .resizeAspectFill
        isPictureInPictureSupported = AVPictureInPictureController.isPictureInPictureSupported()

        // Live camera: nil timebase lets the layer follow buffer timestamps (avoids Swift/C API mismatch for CMTimebase).
        sampleBufferDisplayLayer.controlTimebase = nil
    }

    deinit {
        removePipControllerObservations()
    }

    /// Call from the main thread when the inline host view lays out. PiP should be prepared only with non-zero bounds **and** when the layer is in a `window` (per AVKit).
    func inlineHostUpdated(bounds: CGRect, isInWindow: Bool) {
        assert(Thread.isMainThread)
        sampleBufferDisplayLayer.frame = CGRect(origin: .zero, size: bounds.size)
        let nonEmpty = bounds.width > 1 && bounds.height > 1
        preparePictureInPictureControllerIfNeeded(inlineBoundsNonEmpty: nonEmpty, inlineHostInWindow: isInWindow)
        refreshPiPState()
    }

    /// Call when inline bounds are known and non-zero (e.g. from `UIViewRepresentable`).
    func preparePictureInPictureControllerIfNeeded(inlineBoundsNonEmpty: Bool, inlineHostInWindow: Bool = true) {
        guard isPictureInPictureSupported, inlineBoundsNonEmpty, inlineHostInWindow else { return }
        guard !prepared else { return }
        prepared = true

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller
        installPipControllerObservations()
        refreshPiPState()
    }

    /// Tear down PiP when the capture session stops so the next session can prepare again with valid bounds.
    func resetForCaptureSessionEnded() {
        DispatchQueue.main.async { [weak self] in
            self?.performResetForCaptureSessionEnded()
        }
    }

    private func performResetForCaptureSessionEnded() {
        pipController?.stopPictureInPicture()
        removePipControllerObservations()
        pipController = nil
        prepared = false
        flushDisplayLayerSync()
        isPictureInPicturePossible = false
        isPictureInPictureActive = false
    }

    /// `AVSampleBufferDisplayLayer` is hosted in UIKit; keep `enqueue` / `flush` on the main queue only.
    private func flushDisplayLayerSync() {
        let flush = { [weak self] in
            guard let self else { return }
            self.coalesceLock.lock()
            self.coalescedLatestSampleBuffer = nil
            self.coalescedDrainScheduled = false
            self.coalesceLock.unlock()
            self.sampleBufferDisplayLayer.flushAndRemoveImage()
        }
        if Thread.isMainThread {
            flush()
        } else {
            DispatchQueue.main.sync(execute: flush)
        }
    }

    private func drainCoalescedSampleBuffersOnMain() {
        assert(Thread.isMainThread)
        while true {
            coalesceLock.lock()
            let buffer = coalescedLatestSampleBuffer
            coalescedLatestSampleBuffer = nil
            coalesceLock.unlock()

            guard let buffer else {
                coalesceLock.lock()
                coalescedDrainScheduled = false
                let pending = coalescedLatestSampleBuffer != nil
                coalesceLock.unlock()
                if pending {
                    continue
                }
                return
            }

            if sampleBufferDisplayLayer.status == .failed {
                sampleBufferDisplayLayer.flushAndRemoveImage()
            }
            sampleBufferDisplayLayer.enqueue(buffer)
        }
    }

    private func installPipControllerObservations() {
        removePipControllerObservations()
        guard let pipController else { return }

        pipPossibleObservation = pipController.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, change in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPictureInPicturePossible = change.newValue ?? controller.isPictureInPicturePossible
            }
        }

        pipActiveObservation = pipController.observe(
            \.isPictureInPictureActive,
            options: [.initial, .new]
        ) { [weak self] controller, change in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPictureInPictureActive = change.newValue ?? controller.isPictureInPictureActive
            }
        }
    }

    private func removePipControllerObservations() {
        pipPossibleObservation?.invalidate()
        pipActiveObservation?.invalidate()
        pipPossibleObservation = nil
        pipActiveObservation = nil
    }

    func refreshPiPState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPictureInPicturePossible = self.pipController?.isPictureInPicturePossible ?? false
            self.isPictureInPictureActive = self.pipController?.isPictureInPictureActive ?? false
        }
    }

    func startPictureInPictureFromMain() {
        guard let pipController, pipController.isPictureInPicturePossible else { return }
        pipController.startPictureInPicture()
    }

    func stopPictureInPictureFromMain() {
        pipController?.stopPictureInPicture()
    }
}

extension PictureInPictureBridge: CameraSampleBufferTee {
    func sessionDidStop() {
        flushDisplayLayerSync()
        DispatchQueue.main.async { [weak self] in
            self?.pipController?.stopPictureInPicture()
        }
        resetForCaptureSessionEnded()
    }

    func tee(sampleBuffer: CMSampleBuffer, source: CameraVideoSource) {
        let mode = cameraModeProvider()
        let include: Bool
        switch mode {
        case .back:
            include = source == .back
        case .front:
            include = source == .front
        case .both:
            include = source == .back
        }
        guard include else { return }

        coalesceLock.lock()
        coalescedLatestSampleBuffer = sampleBuffer
        let kick = !coalescedDrainScheduled
        if kick {
            coalescedDrainScheduled = true
        }
        coalesceLock.unlock()
        guard kick else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drainCoalescedSampleBuffersOnMain()
        }
    }
}

extension PictureInPictureBridge: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying _: Bool
    ) {
        // Live camera: do not honor PiP “pause” for the sample-buffer path or the inline layer stops updating.
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        refreshPiPState()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }
}

extension PictureInPictureBridge: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { [weak self] in
            self?.isPictureInPictureActive = true
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { [weak self] in
            self?.isPictureInPictureActive = false
            self?.refreshPiPState()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let text = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            self?.onPiPFailureMessage?(text.isEmpty ? "Picture in Picture could not start." : text)
            self?.refreshPiPState()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

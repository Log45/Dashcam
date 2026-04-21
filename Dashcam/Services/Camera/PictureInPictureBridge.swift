import AVFoundation
import AVKit
import Combine
import CoreMedia
import UIKit

/// Feeds one camera stream into `AVSampleBufferDisplayLayer` and drives PiP so capture can continue over other apps (e.g. Maps).
final class PictureInPictureBridge: NSObject, ObservableObject {
    /// Shown inline and used as the PiP content source (must stay in a view hierarchy while PiP may be active).
    let sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()

    @Published private(set) var isPictureInPictureSupported = false
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var isPictureInPictureActive = false

    /// Match `DashcamViewModel.effectiveCameraMode` for which stream to mirror into PiP.
    var cameraModeProvider: () -> CameraMode = { .back }

    private var pipController: AVPictureInPictureController?
    private var playbackPaused = false
    private var prepared = false

    override init() {
        super.init()
        sampleBufferDisplayLayer.videoGravity = .resizeAspectFill
        isPictureInPictureSupported = AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// Call once the display layer is in a window hierarchy (e.g. from `UIViewRepresentable`).
    func preparePictureInPictureControllerIfNeeded() {
        guard isPictureInPictureSupported, !prepared else { return }
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
        refreshPiPState()
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
        sampleBufferDisplayLayer.flushAndRemoveImage()
        DispatchQueue.main.async { [weak self] in
            self?.pipController?.stopPictureInPicture()
        }
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

        if sampleBufferDisplayLayer.status == .failed {
            sampleBufferDisplayLayer.flushAndRemoveImage()
        }
        sampleBufferDisplayLayer.enqueue(sampleBuffer)
    }
}

extension PictureInPictureBridge: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        playbackPaused = !playing
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
        playbackPaused
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
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

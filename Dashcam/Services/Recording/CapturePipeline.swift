import AVFoundation
import Foundation

/// Bridges camera sample buffers into one or two rolling recorders.
final class CapturePipeline: CameraSampleBufferConsumer {
    private var backRecorder: RollingSegmentRecorder?
    private var frontRecorder: RollingSegmentRecorder?

    init(mode: CameraMode, bufferWindowSeconds: Double) {
        switch mode {
        case .back:
            backRecorder = RollingSegmentRecorder(source: .back, bufferWindowSeconds: bufferWindowSeconds)
        case .front:
            frontRecorder = RollingSegmentRecorder(source: .front, bufferWindowSeconds: bufferWindowSeconds)
        case .both:
            backRecorder = RollingSegmentRecorder(source: .back, bufferWindowSeconds: bufferWindowSeconds)
            frontRecorder = RollingSegmentRecorder(source: .front, bufferWindowSeconds: bufferWindowSeconds)
        }
    }

    func updateBufferWindow(seconds: Double) {
        backRecorder?.updateBufferWindow(seconds: seconds)
        frontRecorder?.updateBufferWindow(seconds: seconds)
    }

    func ingest(sampleBuffer: CMSampleBuffer, source: CameraVideoSource) {
        switch source {
        case .back:
            backRecorder?.ingest(sampleBuffer: sampleBuffer)
        case .front:
            frontRecorder?.ingest(sampleBuffer: sampleBuffer)
        }
    }

    func flushAll(completion: @escaping () -> Void) {
        let group = DispatchGroup()
        if let backRecorder {
            group.enter()
            backRecorder.flush { group.leave() }
        }
        if let frontRecorder {
            group.enter()
            frontRecorder.flush { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    func collectSegmentURLs(seconds: Double, completion: @escaping ([CameraVideoSource: [URL]]) -> Void) {
        let group = DispatchGroup()
        let mergeLock = NSLock()
        var result: [CameraVideoSource: [URL]] = [:]

        if let backRecorder {
            group.enter()
            backRecorder.segmentURLsCoveringLast(seconds: seconds) { urls in
                mergeLock.lock()
                if !urls.isEmpty { result[.back] = urls }
                mergeLock.unlock()
                group.leave()
            }
        }
        if let frontRecorder {
            group.enter()
            frontRecorder.segmentURLsCoveringLast(seconds: seconds) { urls in
                mergeLock.lock()
                if !urls.isEmpty { result[.front] = urls }
                mergeLock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(result)
        }
    }

    func discard() {
        backRecorder?.reset()
        frontRecorder?.reset()
        backRecorder = nil
        frontRecorder = nil
    }
}

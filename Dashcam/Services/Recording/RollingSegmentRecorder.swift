import AVFoundation
import Foundation

/// Bridges `CMSampleBuffer` across queues without claiming it is actually `Sendable`.
private struct SampleBufferSendToken: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

/// Disk-backed rolling H.264 segments for one camera stream.
final class RollingSegmentRecorder: @unchecked Sendable {
    struct StoredSegment {
        let url: URL
        let duration: CMTime
    }

    private let writerQueue = DispatchQueue(label: "dashcam.segment.writer")
    private let source: CameraVideoSource
    private let segmentWallSeconds: Double

    private var bufferWindowSeconds: Double
    private var currentWriter: AVAssetWriter?
    private var currentInput: AVAssetWriterInput?
    private var segmentStartWall: Date?
    private var segmentIndex: Int = 0
    private var segments: [StoredSegment] = []
    private var formatDescription: CMFormatDescription?
    private let segmentsDirectory: URL

    init(source: CameraVideoSource, bufferWindowSeconds: Double, segmentWallSeconds: Double = 5) {
        self.source = source
        self.bufferWindowSeconds = bufferWindowSeconds
        self.segmentWallSeconds = segmentWallSeconds
        self.segmentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashcamSegments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(source.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
    }

    func updateBufferWindow(seconds: Double) {
        writerQueue.async { [weak self] in
            self?.bufferWindowSeconds = seconds
            self?.evictIfNeededLocked()
        }
    }

    /// Synchronous teardown (call from the main thread only; not from `writerQueue`).
    func reset() {
        writerQueue.sync { [weak self] in
            self?.resetLocked()
        }
    }

    func ingest(sampleBuffer: CMSampleBuffer) {
        let token = SampleBufferSendToken(buffer: sampleBuffer)
        writerQueue.async { [weak self] in
            self?.ingestLocked(token.buffer)
        }
    }

    func segmentURLsCoveringLast(seconds: Double, completion: @escaping ([URL]) -> Void) {
        writerQueue.async { [weak self] in
            guard let self else {
                completion([])
                return
            }
            let needed = max(0, seconds)
            var chosen: [URL] = []
            var total: Double = 0
            for seg in segments.reversed() {
                chosen.insert(seg.url, at: 0)
                total += seg.duration.seconds
                if total >= needed { break }
            }
            completion(chosen)
        }
    }

    private func resetLocked() {
        currentInput?.markAsFinished()
        currentWriter?.cancelWriting()
        currentWriter = nil
        currentInput = nil
        segmentStartWall = nil
        formatDescription = nil
        segmentIndex = 0

        for seg in segments {
            try? FileManager.default.removeItem(at: seg.url)
        }
        segments.removeAll()
        try? FileManager.default.removeItem(at: segmentsDirectory)
    }

    private func ingestLocked(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if formatDescription == nil {
            formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = Date()

        if currentWriter == nil {
            do {
                try startNewSegmentLocked(firstPTS: pts)
                segmentStartWall = now
            } catch {
                return
            }
        }

        guard let input = currentInput, input.isReadyForMoreMediaData else { return }

        if let startWall = segmentStartWall, now.timeIntervalSince(startWall) >= segmentWallSeconds {
            let rollToken = SampleBufferSendToken(buffer: sampleBuffer)
            finalizeCurrentSegmentLocked { [weak self] in
                guard let self else { return }
                do {
                    try self.startNewSegmentLocked(firstPTS: pts)
                    self.segmentStartWall = now
                    self.appendIfPossibleLocked(rollToken.buffer)
                } catch {}
            }
        } else {
            appendIfPossibleLocked(sampleBuffer)
        }
    }

    private func appendIfPossibleLocked(_ sampleBuffer: CMSampleBuffer) {
        guard let input = currentInput, input.isReadyForMoreMediaData else { return }
        _ = input.append(sampleBuffer)
    }

    private func startNewSegmentLocked(firstPTS: CMTime) throws {
        guard let formatDescription else { throw NSError(domain: "Dashcam", code: 1) }

        let url = segmentsDirectory.appendingPathComponent("seg_\(segmentIndex).mp4")
        segmentIndex += 1

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dims.width,
            AVVideoHeightKey: dims.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else { throw NSError(domain: "Dashcam", code: 2) }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "Dashcam", code: 3)
        }
        writer.startSession(atSourceTime: firstPTS)

        currentWriter = writer
        currentInput = input
    }

    private func finalizeCurrentSegmentLocked(completion: @escaping () -> Void) {
        guard let writer = currentWriter, let input = currentInput else {
            completion()
            return
        }

        currentWriter = nil
        currentInput = nil
        let url = writer.outputURL

        input.markAsFinished()
        let outputURL = url
        writer.finishWriting { [weak self] in
            guard let self else {
                completion()
                return
            }
            let finishedOK = writer.status == .completed
            if !finishedOK {
                self.writerQueue.async {
                    try? FileManager.default.removeItem(at: outputURL)
                    completion()
                }
                return
            }

            Task { [weak self] in
                let asset = AVURLAsset(url: outputURL)
                let duration = (try? await asset.load(.duration)) ?? .invalid
                guard let self else {
                    completion()
                    return
                }
                self.writerQueue.async { [weak self] in
                    guard let self else {
                        completion()
                        return
                    }
                    if duration.isNumeric && duration.seconds > 0.05 {
                        self.segments.append(StoredSegment(url: outputURL, duration: duration))
                        self.evictIfNeededLocked()
                    } else {
                        try? FileManager.default.removeItem(at: outputURL)
                    }
                    completion()
                }
            }
        }
    }

    private func evictIfNeededLocked() {
        var total: Double = 0
        for seg in segments {
            total += seg.duration.seconds
        }
        while total > bufferWindowSeconds + 0.25, let first = segments.first {
            try? FileManager.default.removeItem(at: first.url)
            total -= first.duration.seconds
            segments.removeFirst()
        }
    }

    func flush(completion: @escaping () -> Void) {
        writerQueue.async { [weak self] in
            self?.finalizeCurrentSegmentLocked {
                completion()
            }
        }
    }
}

private extension CMTime {
    var seconds: Double {
        guard isNumeric, !isIndefinite else { return 0 }
        return CMTimeGetSeconds(self)
    }
}

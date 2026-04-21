import AVFoundation
import Foundation

enum ClipExporterError: Error {
    case noSegments
    case exportFailed(String?)
}

/// Holds `AVAssetExportSession` for use from `@Sendable` export completion handlers.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

enum ClipExporter {
    /// Concatenates segment files (same camera) into one MP4.
    static func export(videoSegmentURLs: [URL], to destinationURL: URL, progress: @escaping (Float) -> Void) async throws {
        guard !videoSegmentURLs.isEmpty else { throw ClipExporterError.noSegments }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let mixComposition = AVMutableComposition()
        guard let compositionVideoTrack = mixComposition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ClipExporterError.exportFailed("No composition track")
        }

        var cursor = CMTime.zero
        var firstTransform: CGAffineTransform = .identity

        for (index, url) in videoSegmentURLs.enumerated() {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0 else { continue }

            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            try compositionVideoTrack.insertTimeRange(range, of: track, at: cursor)
            if index == 0 {
                firstTransform = (try? await track.load(.preferredTransform)) ?? .identity
                compositionVideoTrack.preferredTransform = firstTransform
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        guard CMTimeCompare(cursor, .zero) > 0 else {
            throw ClipExporterError.noSegments
        }

        guard let exporter = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ClipExporterError.exportFailed("Could not create export session")
        }

        exporter.outputURL = destinationURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        let box = ExportSessionBox(exporter)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    let session = box.session
                    progress(session.progress)
                    switch session.status {
                    case .completed, .failed, .cancelled:
                        return
                    default:
                        break
                    }
                }
            }

            box.session.exportAsynchronously {
                progressTask.cancel()
                let session = box.session
                let status = session.status
                let errorText = session.error?.localizedDescription
                Task { @MainActor in
                    progress(1.0)
                    switch status {
                    case .completed:
                        continuation.resume()
                    case .failed, .cancelled:
                        continuation.resume(throwing: ClipExporterError.exportFailed(errorText))
                    default:
                        continuation.resume(throwing: ClipExporterError.exportFailed("Unexpected export status"))
                    }
                }
            }
        }
    }
}

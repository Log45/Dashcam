import Foundation

/// Writes timestamped user-acceleration samples to `Documents/DebugLogs/` for tuning collision threshold.
final class AccelerationDebugLogger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dashcam.acceleration.debuglog")
    private var fileHandle: FileHandle?

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Opens or closes the log file when `(isRecording && debugEnabled)` changes.
    /// Uses a synchronous barrier on the logger queue so the file exists before new motion samples are handled.
    func updateSession(isRecording: Bool, debugEnabled: Bool) {
        queue.sync { [weak self] in
            guard let self else { return }
            let shouldRun = isRecording && debugEnabled
            if shouldRun {
                if self.fileHandle == nil {
                    self.openNewLogFile()
                }
            } else {
                self.closeFileLocked()
            }
        }
    }

    func appendSample(ax: Double, ay: Double, az: Double, magnitude: Double, thresholdG: Double, timestamp: Date) {
        queue.async { [weak self] in
            guard let self, let fh = self.fileHandle else { return }
            let ts = self.isoFormatter.string(from: timestamp)
            let line =
                "\(ts)\tax=\(Self.fmt(ax))\tay=\(Self.fmt(ay))\taz=\(Self.fmt(az))\tmagnitude_g=\(Self.fmt(magnitude))\tthreshold_g=\(Self.fmt(thresholdG))\n"
            if let data = line.data(using: .utf8) {
                try? fh.write(contentsOf: data)
            }
        }
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.5f", v)
    }

    private func openNewLogFile() {
        closeFileLocked()
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = docs.appendingPathComponent("DebugLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("acceleration_\(stamp).log", isDirectory: false)
        let header =
            "# Dashcam acceleration debug (user acceleration in g, ~50 Hz while recording)\n# columns: ISO8601_timestamp\tax\tay\taz\tmagnitude_g\tthreshold_g\n"
        guard let headerData = header.data(using: .utf8) else { return }
        FileManager.default.createFile(atPath: url.path, contents: headerData, attributes: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        _ = try? fh.seekToEnd()
        fileHandle = fh
    }

    private func closeFileLocked() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }
}

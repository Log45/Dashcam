import CoreMotion
import Foundation

/// Heuristic spike detection on user acceleration with cooldown.
/// `userAcceleration` is expressed in **g** (Earth gravities) on iOS.
final class CollisionMonitor {
    private let motionManager = CMMotionManager()
    private var lastEventDate: Date?
    private let queue = OperationQueue()

    var thresholdG: Double = 2.5
    var cooldownSeconds: Double = 8

    var onSpike: (() -> Void)?

    /// Every device-motion sample (~50 Hz): ax, ay, az (g), magnitude (g), threshold (g), sample time.
    var onRawAccelerationSample: ((Double, Double, Double, Double, Double, Date) -> Void)?

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        queue.maxConcurrentOperationCount = 1
        queue.name = "dashcam.motion"

        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
        motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let a = motion.userAcceleration
            let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            let now = Date()
            self.onRawAccelerationSample?(a.x, a.y, a.z, magnitude, self.thresholdG, now)
            if magnitude < self.thresholdG {
                return
            }

            if let last = self.lastEventDate, now.timeIntervalSince(last) < self.cooldownSeconds {
                return
            }
            self.lastEventDate = now
            DispatchQueue.main.async {
                self.onSpike?()
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    #if DEBUG
    func simulateSpike() {
        DispatchQueue.main.async { [weak self] in
            self?.onSpike?()
        }
    }
    #endif
}

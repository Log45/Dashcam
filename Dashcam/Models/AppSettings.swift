import Combine
import Foundation
import SwiftUI

enum CameraMode: String, CaseIterable, Identifiable {
    case back
    case front
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .back: return "Back"
        case .front: return "Front"
        case .both: return "Both"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var cameraMode: CameraMode {
        didSet { defaults.set(cameraMode.rawValue, forKey: Keys.cameraMode) }
    }

    @Published var bufferSeconds: Double {
        didSet { defaults.set(bufferSeconds, forKey: Keys.bufferSeconds) }
    }

    @Published var collisionThresholdG: Double {
        didSet { defaults.set(collisionThresholdG, forKey: Keys.collisionThresholdG) }
    }

    @Published var collisionCooldownSeconds: Double {
        didSet { defaults.set(collisionCooldownSeconds, forKey: Keys.collisionCooldown) }
    }

    @Published var debugAccelerationLogging: Bool {
        didSet { defaults.set(debugAccelerationLogging, forKey: Keys.debugAccelerationLogging) }
    }

    private enum Keys {
        static let cameraMode = "cameraMode"
        static let bufferSeconds = "bufferSeconds"
        static let collisionThresholdG = "collisionThresholdG"
        static let collisionCooldown = "collisionCooldownSeconds"
        static let debugAccelerationLogging = "debugAccelerationLogging"
    }

    init() {
        let raw = defaults.string(forKey: Keys.cameraMode) ?? CameraMode.back.rawValue
        cameraMode = CameraMode(rawValue: raw) ?? .back
        let buf = defaults.object(forKey: Keys.bufferSeconds) as? Double ?? 60
        bufferSeconds = buf
        collisionThresholdG = defaults.object(forKey: Keys.collisionThresholdG) as? Double ?? 2.5
        collisionCooldownSeconds = defaults.object(forKey: Keys.collisionCooldown) as? Double ?? 8
        debugAccelerationLogging = defaults.bool(forKey: Keys.debugAccelerationLogging)
    }

    var bufferSecondsClamped: Double {
        min(180, max(15, bufferSeconds))
    }

    var collisionThresholdClamped: Double {
        min(6, max(1.2, collisionThresholdG))
    }

    var collisionCooldownClamped: Double {
        min(30, max(3, collisionCooldownSeconds))
    }
}

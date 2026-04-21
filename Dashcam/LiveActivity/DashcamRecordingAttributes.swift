import ActivityKit
import Foundation

/// Shared between the app (request) and the Widget extension (presentation). Keep fields stable.
struct DashcamRecordingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var line: String

        public init(line: String) {
            self.line = line
        }
    }

    public var title: String

    public init(title: String) {
        self.title = title
    }
}

import Foundation

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.2, *)
private enum RecordingLiveActivityRunner {
    private static var activity: Activity<DashcamRecordingAttributes>?

    static func start() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }
        let attributes = DashcamRecordingAttributes(title: "Dashcam")
        let state = DashcamRecordingAttributes.ContentState(line: "Recording")
        let content = ActivityContent(state: state, staleDate: nil)
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        } catch {}
    }

    static func end() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
#endif

enum RecordingLiveActivityBootstrap {
    static func startIfAvailable() {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            Task { await RecordingLiveActivityRunner.start() }
        }
        #endif
    }

    static func endIfAvailable() {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            Task { await RecordingLiveActivityRunner.end() }
        }
        #endif
    }
}

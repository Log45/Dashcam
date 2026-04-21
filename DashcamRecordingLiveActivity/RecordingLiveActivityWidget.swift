import ActivityKit
import SwiftUI
import WidgetKit

struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DashcamRecordingAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                    Text(context.attributes.title)
                        .font(.headline)
                }
                Text(context.state.line)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.5))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "record.circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.red, .primary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Dashcam")
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            } compactTrailing: {
                Text("REC")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
            } minimal: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            }
        }
    }
}

@main
struct RecordingLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivityWidget()
    }
}

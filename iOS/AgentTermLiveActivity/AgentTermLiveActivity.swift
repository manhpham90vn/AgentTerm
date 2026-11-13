import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity of the agents on a Mac (#24), on the lock screen and in
/// the Dynamic Island. Touching it opens the app on the session that waits.
@main
struct AgentTermLiveActivities: WidgetBundle {
    var body: some Widget {
        AgentsLiveActivity()
    }
}

struct AgentsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentsActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.waiting.isEmpty ? "circle.dotted" : "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(context.state.waiting.isEmpty ? .blue : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agents on \(context.attributes.mac)").font(.headline)
                    Text(context.state.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .widgetURL(link(context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "terminal").foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.summary).font(.subheadline).lineLimit(2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.mac).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: context.state.waiting.isEmpty ? "circle.dotted" : "hand.raised.fill")
                    .foregroundStyle(context.state.waiting.isEmpty ? .blue : .orange)
            } compactTrailing: {
                Text("\(context.state.working + context.state.waiting.count)")
            } minimal: {
                Image(systemName: context.state.waiting.isEmpty ? "circle.dotted" : "hand.raised.fill")
                    .foregroundStyle(context.state.waiting.isEmpty ? .blue : .orange)
            }
            .widgetURL(link(context.state))
        }
    }

    /// Opens the app, on the session that waits when one does.
    private func link(_ state: AgentsActivityAttributes.ContentState) -> URL? {
        let scheme = Bundle.main.object(forInfoDictionaryKey: "AppLinkScheme") as? String ?? "agentterm"
        return URL(string: "\(scheme)://session" + (state.firstWaiting.map { "?id=\($0)" } ?? ""))
    }
}

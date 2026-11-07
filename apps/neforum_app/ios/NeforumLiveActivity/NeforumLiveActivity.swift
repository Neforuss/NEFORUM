import ActivityKit
import SwiftUI
import WidgetKit

/// The extension's entry point. A Live Activity has no network and runs no code of
/// NEFORUM's: it draws `ContentState`, and iOS itself flips `isStale` at the date the
/// app set, which is how it can say "Paused by iOS" while the app is frozen.
@main
struct NeforumLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    PublishLiveActivity()
  }
}

struct PublishLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: PublishActivityAttributes.self) { context in
      PublishLockScreenView(state: context.state, isStale: context.isStale)
        .padding(16)
    } dynamicIsland: { context in
      let state = context.state
      let stale = context.isStale
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          PublishMark(isStale: stale).font(.title2)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(state.line(isStale: stale))
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
        }
        DynamicIslandExpandedRegion(.bottom) {
          PublishDetailView(state: state, isStale: stale)
        }
      } compactLeading: {
        PublishMark(isStale: stale)
      } compactTrailing: {
        Text(state.shortLine(isStale: stale))
          .font(.caption2.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      } minimal: {
        PublishMark(isStale: stale)
      }
    }
  }
}

/// Not by colour alone: the shape changes when the run is paused.
struct PublishMark: View {
  let isStale: Bool

  var body: some View {
    Image(systemName: isStale ? "pause.circle.fill" : "paperplane.fill")
      .foregroundStyle(isStale ? Color.orange : Color.accentColor)
  }
}

struct PublishDetailView: View {
  let state: PublishActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let detail = state.detail(isStale: isStale) {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let bar = state.bar(isStale: isStale) {
        ProgressView(value: Double(bar), total: 1000)
      }
    }
  }
}

struct PublishLockScreenView: View {
  let state: PublishActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        PublishMark(isStale: isStale)
        Text(state.line(isStale: isStale))
          .font(.headline)
          .lineLimit(3)
      }
      PublishDetailView(state: state, isStale: isStale)
    }
  }
}

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

/// Every presentation carries the run's progress: the expanded island, the compact
/// pill (ring and count), and the minimal circle (ring) that iOS shows when another
/// activity shares the island.
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
          PublishMark(isPaused: state.showsPause(isStale: stale)).font(.title2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          PublishCount(state: state, isStale: stale)
            .font(.subheadline.weight(.semibold))
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
        PublishRing(state: state, isStale: stale)
      } compactTrailing: {
        // The count at all times; a failure adds the badge beside it.
        PublishCount(state: state, isStale: stale)
          .font(.caption2.weight(.semibold))
      } minimal: {
        PublishRing(state: state, isStale: stale)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text(state.line(isStale: stale)))
      }
    }
  }
}

/// Not by colour alone: the shape changes when the run is paused. Inside the ring
/// the pause shape drops its own circle, since the ring is one already.
struct PublishMark: View {
  let isPaused: Bool
  var inRing = false

  var body: some View {
    Image(systemName: isPaused ? (inRing ? "pause.fill" : "pause.circle.fill") : "paperplane.fill")
      .foregroundStyle(isPaused ? Color.orange : Color.accentColor)
  }
}

/// The mark inside a ring that fills with the post's figure. Stale, the ring keeps
/// only its track: an arc would look as if it were still moving.
struct PublishRing: View {
  let state: PublishActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.white.opacity(0.25), lineWidth: 2.5)
      if let fraction = state.ring(isStale: isStale), fraction > 0 {
        Circle()
          .trim(from: 0, to: CGFloat(fraction))
          .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
      PublishMark(isPaused: state.showsPause(isStale: isStale), inRing: true)
        .font(.system(size: 10, weight: .bold))
    }
    .frame(width: 22, height: 22)
    .accessibilityHidden(true)
  }
}

/// "2/5", and the red badge beside it when a network failed. The badge never
/// replaces the count.
struct PublishCount: View {
  let state: PublishActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    HStack(spacing: 3) {
      Text(state.shortLine(isStale: isStale))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      if let failure = state.failure() {
        PublishFailureBadge()
          .accessibilityLabel(Text(failure))
      }
    }
  }
}

/// A white exclamation mark on a red circle.
struct PublishFailureBadge: View {
  var body: some View {
    Image(systemName: "exclamationmark.circle.fill")
      .symbolRenderingMode(.palette)
      .foregroundStyle(Color.white, Color.red)
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
      // In words where there is room: the Lock Screen and the expanded island.
      if let failure = state.failure() {
        Text(failure)
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.red)
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
        PublishMark(isPaused: state.showsPause(isStale: isStale))
        Text(state.line(isStale: isStale))
          .font(.headline)
          .lineLimit(3)
      }
      PublishDetailView(state: state, isStale: isStale)
    }
  }
}

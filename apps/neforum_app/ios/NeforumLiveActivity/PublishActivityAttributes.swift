import ActivityKit
import Foundation

/// Compiled into both Runner and the NeforumLiveActivity extension. Everything the
/// activity shows travels in `ContentState`: no App Group, because re-signing tools
/// rename App Groups and that leaves a Live Activity blank.
///
/// All wording comes from lib/state/publish_run_surface.dart. The post's text never
/// comes here: a Lock Screen is public.
@available(iOS 16.2, *)
struct PublishActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var phase: String
    var label: String
    /// The count beside the camera, "2/5". Live, stale and held back alike.
    var shortLabel: String
    /// What the activity reads once it is stale. Sent ahead with every update,
    /// because a frozen app cannot send anything at that moment.
    var pausedLabel: String
    var pausedShortLabel: String
    var stageLabel: String?
    var network: String?
    /// The post's figure, out of 1000. Null when there is none to show.
    var permille: Int?
    /// "1 failed" when a network failed: the red badge, and its words. Optional,
    /// so an activity encoded by an older build still decodes.
    var failedLabel: String?
    /// Held back with the app about to be frozen: the pause shape before iOS's own
    /// stale flip. Optional for the same reason.
    var paused: Bool?
    var updatedAt: Date
  }

  var postId: String
}

@available(iOS 16.2, *)
extension PublishActivityAttributes.ContentState {
  /// The one line the activity shows. A stale activity never reads its live words.
  func line(isStale: Bool) -> String { isStale ? pausedLabel : label }

  /// The same, for the small space beside the camera: the count, in both states.
  func shortLine(isStale: Bool) -> String { isStale ? pausedShortLabel : shortLabel }

  /// What is happening right now. Nothing once it is stale: nobody knows.
  func detail(isStale: Bool) -> String? { isStale ? nil : stageLabel }

  /// The bar. Nothing once it is stale: it would look as if it were still moving.
  func bar(isStale: Bool) -> Int? { isStale ? nil : permille }

  /// The ring around the mark in the compact and minimal island, from 0 to 1. It
  /// follows the bar, so a stale ring has no arc, only its track.
  func ring(isStale: Bool) -> Double? {
    guard let value = bar(isStale: isStale) else { return nil }
    return min(1, max(0, Double(value) / 1000))
  }

  /// The pause shape: iOS flipped the activity stale, or the app held the run back.
  func showsPause(isStale: Bool) -> Bool { isStale || paused == true }

  /// The badge's words, or nil for no badge. A failure stays true once stale.
  func failure() -> String? {
    guard let failedLabel = failedLabel, !failedLabel.isEmpty else { return nil }
    return failedLabel
  }
}

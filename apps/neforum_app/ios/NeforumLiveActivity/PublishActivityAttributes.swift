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
    var shortLabel: String
    /// What the activity reads once it is stale. Sent ahead with every update,
    /// because a frozen app cannot send anything at that moment.
    var pausedLabel: String
    var pausedShortLabel: String
    var stageLabel: String?
    var network: String?
    /// The post's figure, out of 1000. Null when there is none to show.
    var permille: Int?
    var updatedAt: Date
  }

  var postId: String
}

@available(iOS 16.2, *)
extension PublishActivityAttributes.ContentState {
  /// The one line the activity shows. A stale activity never reads its live words.
  func line(isStale: Bool) -> String { isStale ? pausedLabel : label }

  /// The same, for the small space beside the camera.
  func shortLine(isStale: Bool) -> String { isStale ? pausedShortLabel : shortLabel }

  /// What is happening right now. Nothing once it is stale: nobody knows.
  func detail(isStale: Bool) -> String? { isStale ? nil : stageLabel }

  /// The bar. Nothing once it is stale: it would look as if it were still moving.
  func bar(isStale: Bool) -> Int? { isStale ? nil : permille }
}

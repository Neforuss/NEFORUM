# A post while NEFORUM is not on screen (iOS)

For anyone changing `lib/state/publish_run_surface.dart`, `lib/state/publish_run_session.dart`, `ios/Runner/PublishRunKeeper.swift` or `ios/NeforumLiveActivity/`.

## What iOS allows

A suspended app runs no code. A Dart isolate stops with the process. So nothing here can tick, poll, or post while iOS has the app paused, and nothing claims to.

| What | Time | Where |
|---|---|---|
| Background assertion, taken at the tap | About 30 s, not guaranteed | Every version |
| `BGContinuedProcessingTask`, from a tap with the app in front | Minutes, best effort, ends when iOS wants | iOS 26 and later |
| Live Activity | Shows, updates only while the app runs | iOS 16.2 and later, extension present, not turned off |

## Two things that need no running code

1. **The stale flip.** Every Live Activity update sets `staleDate` to now + 45 s and carries the words to show after it. If the process freezes, iOS flips `isStale` by itself and the widget reads `pausedLabel`. The widget's only way to its text is `line(isStale:)`, so "Posting" cannot show on a stale activity.
2. **The dead-man notification.** On leaving the app mid-run, a local notification is set for now + 45 s under `paused:<postId>`. Each 15 s heartbeat pushes it back. If the heartbeat stops, the system delivers it. It is on `NotificationService.postKeys`, so deleting the post removes it. It needs notification permission.

## What each surface says

All wording comes from `reducePublishSurface`. Native code has no words of its own, by test.

| State | In the app | Live Activity | Notification |
|---|---|---|---|
| Preparing | Getting your post ready… | Nothing | None |
| Posting, app open | Sheet, plus "If you leave, iOS may pause this." | Posting 2 of 5 | None |
| Left, time granted | Same on return | Posting 2 of 5 | Armed, not shown |
| Waiting on a network | The network's words, no invented figure | Instagram is processing | Armed |
| Paused by iOS | On return: iOS paused NEFORUM. Continuing. | Paused by iOS. 2 of 5 posted. Open NEFORUM to finish. | Posting paused by iOS. 2 of 5 posted, 3 to go. Open NEFORUM to finish. |
| Back in the app | Goes on by itself | Posting 3 of 5 | Cancelled |
| Stopped (system expiry or Stop in iOS's own view, which look alike) | Stopped. 2 of 5 posted. Continue, Cancel the rest | Ended | Stopped. Open NEFORUM to continue. |
| Closed (iOS killed it or a person swiped it away, which look alike) | Activity: NEFORUM was closed before this finished. 2 of 5 posted. Continue | Stale until ended at the next launch | The dead-man fired already |
| Unknown result | Threads: NEFORUM could not confirm this. Check Threads before retrying. | Counted as not finished | In the result notification |
| Done | Posted to 5 of 5 | Final words, then gone after 30 minutes | Result, if on |
| Partly done | Posted to 3 of 5, 2 failed, with Retry | Final words | Result |

Preparing shows nothing outside the app by design, so a person who leaves in those seconds gets no Live Activity, since iOS only starts one with the app in front. The run itself is unaffected.

## Pausing safely

`windowClosing` (the assertion is about to lapse with no continued task) and `timedOut` (the continued task ended) both set `PublishPauseSignal`. While it is set no new `AdapterContext.creating` starts, and uploads go on. A target held back there has spent no attempt on disk. A request already out when the process froze is `outcomeUnknown` and is never sent again by itself.

Coming back from a hold goes on by itself. A stopped run waits for Continue or Cancel the rest, because Continue is a tap and a tap may ask iOS for a new continued task.

## The numbers

- `update` calls arrive at most every 200 ms from the tracker plus a 15 s heartbeat. The Live Activity applies each stage or outcome change and otherwise at most one update in 30 s.
- iOS's own bar uses 1,000,000 units: `postPermille * 1000 + min(999, poll requests made in this wait)`. Apple ends tasks that report no progress. Each unit is a request that really happened, the bar moves under 0.1%, and the subtitle says "Waiting for {network}". NEFORUM's own figures do not move during a wait.

## Reminders

A text post's "Publish now" runs in a background isolate. `AppDelegate` takes an assertion before the notification plugin's early completion handler, and `end` in `lib/main.dart` gives it back. A post with files gets a button that opens the app: a file can take longer than that time, and only a tap with the app in front may ask for more.

## Not done on purpose

- No App Group: re-signing renames it, and the activity goes blank.
- No `live_activities` plugin and no workmanager continued task: see `ios.md` in the 1.4 research.
- No background `URLSession`: it moves one file, and the post still cannot be made.
- Runs the scheduler starts by itself do not ask for time: iOS keeps continued tasks for a person's tap. `outcomeUnknown` still covers a frozen request there.

## Compiled only in CI, unproved on a phone

Swift compiles only on a Mac. The `ios` job builds the extension and checks the IPA. The `ios-live-activity` job runs the activity on a simulator with an island and reads the screenshots. A phone must still settle these:

| Question | Check |
|---|---|
| Does the widget redraw at `staleDate` with the app suspended | iOS 26 and iOS 18 phones, lock the screen mid-post |
| Does the continued task start on a free Apple ID, and through AltStore or Sideloadly, whose renamed bundle may not match `org.neforum.neforumApp.*` | Run a post, watch for iOS's own view. A refusal only costs the longer time |
| Does registering a continued task after launch work without a crash when the wildcard does not match | Same phones. `register` is documented to return false |
| Do both activities look right together on iOS 26 | If not, set `kOwnActivityBesideContinuedTask` to false |
| Does a pending notification fire after a force quit | Swipe the app away mid-post |
| Does an iOS 15 phone install the IPA and ignore the 16.2 extension | Any iOS 15 device |
| Does Time Sensitive do anything on a self-signed build | Low priority |

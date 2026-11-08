# What the numbers on a publish run mean

For anyone changing `packages/neforum_core/lib/src/publish/publish_progress.dart` or an adapter's publish path.

## The rule

A number on screen tracks what the server confirmed: bytes it answered for, a step it answered for, or a number it sent. Nothing else moves it, and it never goes backward. Anything else shows as words and elapsed time.

## Bytes

`BodyProgress.sent` is bytes handed to the connection, not bytes the server has. The operating system and the path buffer them: in a compiled Windows run against a server reading at 1 Mbit/s, the connection took a 3 MiB body in about 50 ms while the server had 0.5% of it, and it took 25 s more to read the rest. So handed-over bytes move no number at all. Only a confirmed position does (`ProgressEvent.confirmed`):

- the server's answer to a request, with a success (2xx): the whole body of that request counts once its upload request returns OK;
- a chunk the server answered (X, LinkedIn, TikTok chunks);
- a resume offset the server sent (`ctx.uploadOffset`, YouTube).

An upload the adapter moved on from also counts in full: it moves on only once each upload request was answered. That covers bodies too small to watch and files the server had from an earlier attempt.

What the screens do with it:

- While bytes are on the way and the server has confirmed none of them, the row says "Uploading image 1 of 1 · Sending 3.0 MB to Mastodon · 0:12" and shows no number. Its bar and the post's number stay where they were. The words say "Sending", never "sent", "received" or "has": the server may have none of it yet.
- Once the server confirms part of the open upload, the row says "Mastodon has 1.2 MB of 5.0 MB" with its number. That is the server's own figure.
- A figure stops at 99.0% until an outcome. 100% means the network answered, or this run is finished with that target.

So a one-request upload on a slow link holds its number for the whole upload and moves once, on the answer. That is the price of never claiming bytes the server may not have. A chunked upload moves chunk by chunk.

Files under 64 KiB go over in one piece and report once, on the answer. Small JSON and form calls report nothing: they are not uploads. A browser collects the whole body before sending any, so on the web build every upload reports only on its answer.

The plain language upload error does not state a byte figure as fact: the figure goes in the details box, worded "handed to the connection".

## A target's figure

`kProgressWeights` shares a target's 100% between upload, server wait and posting, per `ProgressFamily`. Each row sums to 100, by test.

| Family | Upload | Wait | Posting | Who |
|---|---|---|---|---|
| direct | 90 | 0 | 10 | The default |
| waitNoNumber | 70 | 20 | 10 | Mastodon, Pixelfed, Nostr, LinkedIn video, Pinterest video, Reddit image and video, TikTok video |
| waitReported | 70 | 20 | 10 | X video and GIF, Bluesky video |
| pullFromUrl | 60 | 30 | 10 | Instagram, Threads, TikTok photos |
| wholeFile | 95 | 0 | 5 | YouTube |
| textOnly | 0 | 0 | 100 | Any post with no files |
| opaque | none | none | none | Odysee: words and elapsed time until the outcome |

Arithmetic is in integers (permille and parts per million). Doubles compared with `==` have already gone wrong here once.

A figure never falls. A retry, a re-send, a lower resume offset or a fallback host all write a lower position and change nothing until they pass the old mark. Meanwhile `TargetProgress.resending` is true so the words can say why the bar stopped.

`TargetProgress.position` is the last position reported, handed over or confirmed, kept as evidence and for the words. `confirmedPosition` is what the server confirmed of the open upload, null while it has confirmed none of it. `permille` follows confirmed positions only.

## The post's figure

Targets count by `max(planned bytes, 1 MiB)`, fixed when the run starts. A finished text post beside an unstarted 500 MiB upload is 0.2%, not 50%, which is why "Posted to 2 of 5" must always sit beside the number. Targets the run leaves alone are in no figure. A retry credits what is live already.

## Time left

Per target, upload stage only, from `RateMeter`, which is fed confirmed positions only: nothing until two 10 s windows in a row agree within 25%, and nothing once the server has it all. A one-request upload has one confirmed position, its answer, so it never has a speed or a time left. A new attempt, a re-send or a resume from a lower offset starts the measuring over. On unsteady links the row shows bytes and no time. There is never a time left for a whole post, because what remains includes waits nobody can measure. The 25% was tuned on loopback only.

## What the screens show

The words live in `apps/neforum_app/lib/state/publish_progress_view.dart`, which is pure, and `publishProgressProvider` holds the figures of every run this process is executing, by post: the composer's, a retry from a list, the scheduler's. The sheet, Activity and the post's page read the same `PostProgress`, through `PostProgressFigure` and `TargetProgressLine` in `lib/widgets/publish_progress.dart`.

| A network is | Its row says | Bar | Number |
|---|---|---|---|
| Not reached yet | Waiting | none | none |
| Sending, nothing confirmed yet | Its label · Sending 3.0 MB to Mastodon · 0:12 | holds | none |
| Sending, the server confirmed part | Its label, "Mastodon has 1.2 MB of 5.0 MB", and speed and time left once measured | yes | yes |
| Sending again after a drop | Connection dropped, sending again | holds | only if the server confirmed part |
| In a server wait | Its label · 1:12 | holds | only one the network sent |
| Signing in, reading, posting | Its label · 0:07 | holds | none |
| Handing off | Waiting for you | none | none |
| Odysee | Its label · 1:05 | none | none |
| Finished | Its result at once: Open, the error, or a pill | none | none |

Android's notification and the iOS Live Activity and system bar take `postPermille` and each network's figure from the same `PostProgress` (`lib/state/publish_run_surface.dart`), so they follow the same rule. Their words say "Sending to Mastodon" during an upload, never that the server has it. Open point: D6 moves the iOS system bar during a server wait by its poll count, but nothing moves it during a one-request upload with nothing confirmed, so a long single-body upload in the background reports no progress to iOS until its answer. Whether iOS ends such a task early is untested here.

Only rows with no number show the small spinner, and never a row that is queued or waiting for the person. The post's own figure stays on screen during a wait and does not move. Before the plan is known there is no figure, only an indeterminate bar.

The elapsed time is the one thing that moves during a wait, from a one second timer in `TargetProgressLine`. A time left or speed goes away 20 s after the last report, since bytes that stopped have no time left worth stating.

A progress bar's semantic value must parse as a number, or Flutter's debug check throws. Rows in a wait leave their bar out of semantics, so the words are what a screen reader gets.

A run in a background isolate cannot report to this one. `PublishRunStatus` reads the publish journal every 30 s: another owner with a heartbeat from the last two minutes reads "Posting in the background", with no number. No entry (another device's run) or an old heartbeat (it stopped) reads nothing, because saying it is posting would be untrue.

## A request that can make a post

Every API adapter's post call goes through `AdapterContext.creating`. `test/adapters/creating_coverage_test.dart` lists all 30 by name. `test/adapters/creating_lost_answer_test.dart` runs each real adapter and loses the answer on the request inside `creating`, because a name in a list does not prove the call works: a helper that turns a transport error into its own error inside the callback hides the lost answer from `creating`, and the target comes back for a retry that posts twice.

- Before the call it writes `inFlightCreate` to the publish journal, which is never synced.
- If the call ends with no answer, the target fails with `PublishError.outcomeUnknown`, not retryable: "NEFORUM could not confirm this. Check {network} before retrying."
- After a kill, recovery reads the journal and gives that target the same words, not "closed before this was posted".
- A good answer adds the account to `createdUnsaved` in the journal until a save takes the result to disk, so a kill in that gap reads the same way. It holds more than one account when a save failed and the run went on.
- Cancel during the call is a cancelled target with the same warning, unless the body was only partly sent (`OperationCancelledException.notSent`): then nothing can be live and it is a plain cancel.
- A network that has the post before its last wait (TikTok) reports the same warning if that wait cannot finish. Reddit's wait for its media socket ends on Cancel and counts the post as made.
- `idempotent: true` is only for a real dedupe key that holds across attempts: Mastodon's `Idempotency-Key` and YouTube's upload session. Matrix's transaction id is new on each attempt, so it does not count.
- An error that proves the server cannot have acted (no connection was made, or the body never went out whole) stays the ordinary retryable failure. Saying "could not confirm" there would be untrue, and an offline device would never retry a scheduled post.
- `PublishPauseSignal` holds back new `creating` calls and leaves uploads alone.

## The trace

Each finished stage of a run with listeners leaves one local debug line: `Stage uploading: 3000 ms, 100 bytes`. It holds the stage, its time and its bytes, nothing else, and nothing leaves the device.

## Adding an adapter

1. Wrap the post call in `ctx.creating`, and add the adapter to both tests above. Inside the callback, let transport errors through: map them outside it.
2. Open each planned file with `ctx.uploading(m, label)`, or `ctx.uploadingAll(label)` when one body carries them all. Pass `uploads: true` to `creating` when the upload is the post.
3. Pass `bodyOffset` and `bodyWhole` on chunks.
4. Sleep with `ctx.wait`, which Cancel ends, and say `ctx.serverWait(label)` during server waits. Work that is not an HTTP request goes through `ctx.untilCancelled`.
5. Pass `via: ctx.http` to `MediaHost.upload`.
6. Override `progressShape` unless the network is plain direct.

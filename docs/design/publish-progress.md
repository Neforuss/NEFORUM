# What the numbers on a publish run mean

For anyone changing `packages/neforum_core/lib/src/publish/publish_progress.dart` or an adapter's publish path.

## The rule

A number on screen comes from a counted byte, a counted step or a number the network sent. Nothing else moves it. A wait shows words and elapsed time.

## Bytes

`BodyProgress.sent` is bytes handed to the connection, not bytes the server has. On a slow link a 3 MB photo can read "all sent" within a second while the server has 2% of it, so:

- UI words say "sent", never "received".
- A figure stops at 99.0% until an outcome. 100% means the network answered, or this run is finished with that target.
- An answer per chunk or a resume offset is a confirmed position (`ProgressEvent.confirmed`). The speed comes from those alone once any exists.

Files under 64 KiB go over in one piece and report once, on the answer. Small JSON and form calls report nothing: they are not uploads.

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

## The post's figure

Targets count by `max(planned bytes, 1 MiB)`, fixed when the run starts. A finished text post beside an unstarted 500 MiB upload is 0.2%, not 50%, which is why "Posted to 2 of 5" must always sit beside the number. Targets the run leaves alone are in no figure. A retry credits what is live already.

## Time left

Per target, upload stage only, from `RateMeter`: nothing until two 10 s windows in a row agree within 25%, and nothing once all is sent. On unsteady links the row shows bytes and no time. There is never a time left for a whole post, because what remains includes waits nobody can measure. The 25% was tuned on loopback only.

## A request that can make a post

Every API adapter's post call goes through `AdapterContext.creating`, listed by `test/adapters/creating_coverage_test.dart`.

- Before the call it writes `inFlightCreate` to the publish journal, which is never synced.
- If the call ends with no answer, the target fails with `PublishError.outcomeUnknown`, not retryable: "NEFORUM could not confirm this. Check {network} before retrying."
- After a kill, recovery reads the journal and gives that target the same words, not "closed before this was posted".
- A good answer leaves `createdUnsaved` in the journal until the target's result is saved, so a kill in that gap reads the same way.
- `idempotent: true` is only for a real dedupe key that holds across attempts: Mastodon's `Idempotency-Key` and YouTube's upload session. Matrix's transaction id is new on each attempt, so it does not count.
- An error that proves the server cannot have acted (no connection was made, or the body never went out whole) stays the ordinary retryable failure. Saying "could not confirm" there would be untrue, and an offline device would never retry a scheduled post.
- `PublishPauseSignal` holds back new `creating` calls and leaves uploads alone.

## Adding an adapter

1. Wrap the post call in `ctx.creating`, and add the adapter to the coverage test.
2. Open each planned file with `ctx.uploading(m, label)`, or `ctx.uploadingAll(label)` when one body carries them all. Pass `uploads: true` to `creating` when the upload is the post.
3. Pass `bodyOffset` and `bodyWhole` on chunks.
4. Sleep with `ctx.wait`, which Cancel ends, and say `ctx.serverWait(label)` during server waits.
5. Pass `via: ctx.http` to `MediaHost.upload`.
6. Override `progressShape` unless the network is plain direct.

# Android background posting probe

Proves, on an emulator, that a post the person started still reaches the network
after they press Home and remove NEFORUM from Recents. CI runs it in the
`android-background` job of `.github/workflows/build.yml` on API 34 and 36.

## Parts

- `integration_test/android_background_probe.dart`: the app as it ships
  (`runNeforum`), with one Mastodon account on a local server and one post with a
  photo. Once the app is on screen it does what the Post button does
  (`publishExisting`). It checks nothing itself.
- `fake_mastodon.dart`: a Mastodon server on the runner. The photo stays
  "processing" for `--hold` seconds (a real 206), which is the wait the Home press
  and the swipe happen during. Every step is a line in its log.
- `run_probe.sh`: installs the profile APK, starts the app, presses Home, removes
  the task (`am stack remove`, which is what a swipe in Recents calls; the real
  gesture is the fallback), then asserts from the server log that requests and
  exactly one post came after the task was gone, from the same process, and that the
  service stopped afterwards.

## Lanes

| Lane | What it shows | Blocks the build |
|---|---|---|
| `swipe` | The run outlives Home and the task's removal | Yes |
| `limit` | API 35+: with Android's dataSync limit cut to 60 s, `onTimeout` stops the service, the app does not crash, and nothing more is posted | Not yet, it only warns |

## Run it yourself

```bash
cd apps/neforum_app
flutter build apk --profile --target-platform android-x64 -t integration_test/android_background_probe.dart \
  --dart-define=NEFORUM_MOBILE=true --dart-define=NEFORUM_PROBE_SERVER=http://127.0.0.1:8787
# an x86_64 emulator running, adb on the PATH
bash tool/android_background_probe/run_probe.sh swipe
```

`pm clear` wipes the app's data on the emulator first: never point it at a phone with
your own NEFORUM on it. Logs land in `build/android-background-probe/`.

What it does not show: a real phone's vendor killers, Doze over 30 minutes with the
screen off, and Wi-Fi power saving. Those are the device tests T2, T7 and T9 in the
1.4 research.

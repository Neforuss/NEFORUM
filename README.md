<p align="center">
  <img src="apps/neforum_app/assets/brand/icon.png" width="96" alt="NEFORUM logo">
</p>

<h1 align="center">NEFORUM</h1>

<p align="center"><strong>One app, one message, every platform.</strong><br>
A free and open-source cross-poster for Android, iPhone and iPad, macOS and Windows.</p>

<p align="center">
  <img src="docs/screenshots/compose-dark.png" alt="The NEFORUM composer: one post, live previews for every network" width="900">
</p>

Write a post once. NEFORUM adapts it for each network (character limits, threads, hashtags, links, media rules), shows you a live preview of every version, and publishes it everywhere at once or on a schedule.

It does what Buffer, Publer, Metricool, Later or Typefully do for posting, with three differences:

- **Free and open source** (GPL-3.0). No subscription, no per-channel pricing, no NEFORUM account.
- **Every platform works**, including the ones that limit or charge for their API, or only open it to business accounts. Where automatic posting is impossible or paid, NEFORUM hands the finished post to the platform's own app with one tap (see below).
- **Local-first.** There is no NEFORUM server. Your posts go straight from your device to each network. Keys live in your system keychain. No analytics.

## The three ways to post

Every connected account uses one of these. You can connect the same platform more than one way.

| | How it works | Good for |
|---|---|---|
| **Auto** | Posts automatically through the platform's open API. No developer keys, no fees, no review. | Mastodon and the fediverse, Bluesky, Nostr, Misskey, Lemmy, Matrix, Telegram, Discord, WordPress, Ghost, DEV, Micropub |
| **Your keys** | Posts automatically through the official API, using a developer app you create once. NEFORUM tracks the platform's quota and warns you before you hit it. | X, Threads, LinkedIn, YouTube, Reddit, Pinterest, Tumblr, Facebook Pages, Instagram professional accounts, TikTok, Hashnode |
| **Hand-off** | NEFORUM prepares everything: caption on the clipboard, photos in the share sheet, the composer opened with your text. You tap Post. | Any personal account anywhere: Instagram, TikTok, Facebook profiles, Snapchat, WhatsApp, Google Business Profile, Substack Notes, and every platform above when you'd rather not set up keys |

If an API account runs out of quota (for example X's monthly cap), NEFORUM can fall back to hand-off for that post instead of failing.

### Text cards for photo-only networks

Instagram, Pinterest, TikTok photo posts and Snapchat refuse a post without an image. When a post is only words, NEFORUM sets them on a plain card, white on black or black on white, with the same signature every time: a purple rule with a yellow tab along the top, and the NEFORUM mark, wordmark and your handle at the bottom. The card is made on your device when you save or schedule the post. It goes only to the networks that need it (the others get plain text) and carries the words as alt text. The caption still has the full text, hashtags and link. Pick the style per post under the preview, or turn cards off in Settings.

<p align="center">
  <img src="docs/screenshots/text-card-dark.jpg" alt="A NEFORUM text card, white on black" width="260">
  &nbsp;
  <img src="docs/screenshots/text-card-light.jpg" alt="A NEFORUM text card, black on white" width="260">
</p>

<p align="center">
  <img src="docs/screenshots/phone-compose-dark.png" alt="Composer on a phone" width="260">
  &nbsp;
  <img src="docs/screenshots/phone-preview-light.png" alt="Per-network previews on a phone" width="260">
  &nbsp;
  <img src="docs/screenshots/phone-handoff-dark.png" alt="Hand-off to Instagram" width="260">
</p>

## Supported platforms

28 platforms. The full matrix (limits, media, quotas, scheduling) is in [docs/platforms.md](docs/platforms.md), generated from the code. Each platform has a step-by-step setup guide in [docs/platforms](docs/platforms), also shown inside the app.

- **Open networks:** Mastodon and compatible servers (Pleroma, Akkoma, GoToSocial, Friendica, Pixelfed, Mitra), Bluesky, Misskey / Sharkey / Firefish / Iceshrimp, Nostr, Lemmy, Matrix
- **Big platforms:** X, Threads, Facebook, LinkedIn, Reddit, Tumblr
- **Photo and video:** Instagram, TikTok, YouTube, Pinterest, Snapchat
- **Messaging:** Telegram channels and groups, Discord (webhooks), WhatsApp
- **Blogs and newsletters:** WordPress, Ghost, WriteFreely / Write.as, Micropub (IndieWeb, Micro.blog), DEV, Hashnode, Substack Notes
- **Business:** Google Business Profile

### Honest limits (as of October 2026)

These come from the platforms, not from NEFORUM. The setup guides explain each one.

- **X:** new developer accounts are pay-per-use (about $0.015 per post, $0.20 for a post containing a link). No free tier. Hand-off is free.
- **Instagram and Threads (API mode):** Instagram needs a professional (creator or business) account. Both fetch media from a public web address, so you pick a media host in Settings (a free temporary one is built in). Hand-off works with any account and needs none of this.
- **Facebook:** the API only posts to Pages you manage. Personal profiles use hand-off.
- **TikTok:** apps TikTok has not audited can only post privately. Hand-off posts publicly from the TikTok app.
- **YouTube:** uploads from apps that have not passed Google's verification may be locked to private. Google's own pages disagree on whether that still applies, and NEFORUM cannot detect it. Hand-off always posts publicly.
- **Micropub (IndieAuth):** sign-in works on Windows and macOS. On phones, servers that check the app's client page can refuse it until the project publishes that page.
- **Hand-off** always needs one tap from you in the other app, so it cannot run unattended.

## Scheduling without a server

- **Platforms that can hold a post publish it themselves:** Mastodon (and Pleroma, Akkoma, Friendica, GoToSocial 0.20+), Facebook Pages, YouTube, Tumblr, WordPress and Ghost. NEFORUM hands them the post when you schedule it, so it goes out even if your device is off. Editing, rescheduling, publishing now or deleting the post in NEFORUM takes their copy back first. If that fails (offline, expired sign-in), NEFORUM tells you instead of pretending. Threads, private or unlisted YouTube videos, and times too close or too far out stay on the device.
- **Windows and macOS:** for everything else, NEFORUM keeps running in the tray (menu bar) when you close the window and posts on time. It can start when you sign in.
- **Android:** posts go out in the background within a few minutes of their time.
- **iPhone and iPad:** iOS does not let apps run on a timer. Networks that hold posts need nothing from the phone. For the rest you get a notification at the scheduled time; its **Publish now** button posts without opening the app.
- **Hand-off accounts** always get a "time to post" reminder.

## More screenshots

| | |
|---|---|
| ![Accounts](docs/screenshots/accounts-dark.png) | ![Add an account](docs/screenshots/add-account-light.png) |
| ![Queue](docs/screenshots/queue-dark.png) | ![Activity](docs/screenshots/activity-light.png) |
| ![Composer, light theme](docs/screenshots/compose-light.png) | ![Settings](docs/screenshots/settings-dark.png) |

Light and dark themes, six accent colors, and layouts for phones, tablets and wide desktop windows. There is a demo workspace (Settings, then Workspace) to explore everything without connecting real accounts.

## Install

Builds for every platform are produced by [GitHub Actions](.github/workflows/build.yml) on each push.

| Platform | Artifact | Notes |
|---|---|---|
| Android | `neforum-android.apk` | Allow installing from your browser or file manager. Android 7 or newer. |
| Windows | `NEFORUM-Setup-1.0.0.exe` | Installer: no administrator rights needed, Start menu entry, clean uninstall. Or `neforum-windows.zip`: unzip and run `NEFORUM.exe`. Windows 10 or 11, 64-bit; the Visual C++ runtime is included. |
| macOS | `neforum-macos.zip` | Unsigned: right-click the app, then Open, the first time. macOS 10.15 or newer. |
| iPhone and iPad | `neforum-ios-unsigned.ipa` | Sign it with your own Apple ID (Xcode, AltStore or Sideloadly), or build from source in Xcode. |

## Build from source

You need [Flutter 3.47](https://docs.flutter.dev/get-started/install) (Dart 3.13), plus the usual toolchain for your target: Android SDK, Xcode on a Mac for iOS and macOS, or Visual Studio 2022 with "Desktop development with C++" for Windows.

```bash
git clone https://github.com/neforum-app/neforum.git
```

```bash
cd neforum/apps/neforum_app && flutter pub get && dart run tool/sync_docs.dart
```

Then one of:

```bash
flutter build apk --release
```

```bash
flutter build windows --release
```

Then, for the Windows installer (needs [Inno Setup 6](https://jrsoftware.org/isinfo.php)):

```bash
iscc installer\neforum.iss
```

```bash
flutter build macos --release
```

```bash
flutter build ios --release
```

## Project layout

```
packages/neforum_core   Pure-Dart core: data model, 28 platform adapters, text
                        adaptation (counting, threads), quota tracking, OAuth,
                        media hosts, publish service, scheduler. No Flutter.
apps/neforum_app        Flutter app: design system, screens, keychain storage,
                        sign-in, notifications, background work, tray.
docs/platforms          Per-platform setup guides (bundled into the app).
docs/research           The API research the adapters were built from.
docs/design/STYLE.md    Design rules for contributors.
```

Run the tests:

```bash
cd packages/neforum_core && dart test
```

```bash
cd apps/neforum_app && flutter test --exclude-tags screenshots
```

On a desktop, also run the real app with its native plugins (window, tray, keychain, notifications) against a throwaway data folder:

```bash
cd apps/neforum_app && flutter test integration_test -d windows
```

The core has over 1,000 tests that pin every adapter's requests and error handling against mocked APIs, including server-side scheduling and taking a scheduled post back. The app tests render every screen at phone, tablet, desktop and ultrawide sizes in both themes, and drive the main flows end to end, including text cards and platform-held schedules.

## Privacy

NEFORUM has no backend. It stores accounts, posts and settings in your app data folder and secrets in the OS keychain (Keychain on Apple platforms, Keystore on Android, DPAPI on Windows). Network traffic goes only to the platforms you post to and, if you pick one, the media host you configure. Settings, then Data and privacy, lets you export or delete everything.

## License

NEFORUM is free software under the [GNU General Public License v3](LICENSE). Fonts: Inter, Bricolage Grotesque and JetBrains Mono (SIL Open Font License). Platform logos come from Font Awesome Brands (CC BY 4.0) and belong to their owners; NEFORUM is not affiliated with any of the platforms it posts to.

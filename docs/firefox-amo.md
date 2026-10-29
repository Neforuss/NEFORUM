# addons.mozilla.org listing (NEFORUM extension)

Ready-to-paste text for a **listed** submission on addons.mozilla.org (AMO), where Firefox users find the extension and Firefox keeps it updated. (CI's unlisted signing for self-distribution is separate: [signing.md](signing.md).)

Submit at <https://addons.mozilla.org/developers/addon/submit/distribution>, choose **On this site**, and upload `neforum-extension-firefox-<version>.zip` from the GitHub release (or `dist/` after `dart run tool/build_extension.dart` in `apps/neforum_app`). An account is free.

## Before uploading

- Add-on id: `neforum-extension@neforus.com` (in `extensions/browser/manifest.firefox.json`). The first submission, listed or unlisted, ties it to the submitting account.
- `strict_min_version` is 121.0 (Manifest V3 with an event-page background).
- `data_collection_permissions` is `{"required": ["none"]}`: the extension collects and transmits no data. AMO's form shows this as "This add-on does not collect data".
- CI runs `web-ext lint` (the same linter AMO runs on upload) on every build. A warning that `data_collection_permissions` needs Firefox 140 is expected: older Firefox versions ignore the key, and nothing is collected on any version.
- Every version number goes to AMO once (listed and unlisted share the numbering). The first submission is 1.1.2; the next change to the extension needs 1.1.3.

## Describe add-on

**Name**: NEFORUM

**Add-on URL**: `neforum`

**Summary** (250 characters at most):

> Fills in posts you prepared in the NEFORUM desktop app on each network's own page: text, thread parts, poll answers, photos, videos and art site forms. You press Post, or turn on automatic posting in NEFORUM.

**Description**:

```text
The companion extension of NEFORUM, the free and open-source cross-poster (https://neforus.com/neforum/). It needs the NEFORUM desktop app on the same computer (Windows, macOS or Linux).

NEFORUM writes one post for every network. Where a network has no open API, NEFORUM hands the finished post to you: a "hand-off". With this extension, a hand-off opens the network's own page and fills the post in for you:

- the text, and every part of a thread on X, Bluesky and Threads
- photos and videos, uploaded into the composer
- poll and quiz answers on YouTube Posts
- title, description, tags, age rating and AI options on art sites (Behance, ArtStation, Cara, pixiv, Itaku, Newgrounds, Fur Affinity, Weasyl, Ko-fi, Artfol, 500px, Dribbble, Flickr)
- TikTok Studio, Instagram, Facebook, LinkedIn, Pinterest, Reddit, Tumblr, Substack Notes, WhatsApp Web, Google Business Profile, Snapchat
- any other site (a blog, your Mastodon server): click the toolbar button, then "Fill in this page"

You check the post and press Ctrl+Enter or "Post now" in the extension's panel. If you turn on "Post automatically" in NEFORUM, the extension presses the site's Post button itself after a 3-second countdown you can stop, also for scheduled posts while NEFORUM runs. It stays off for X, LinkedIn and Snapchat unless you include them, because their terms forbid scripted posting.

Private by design:
- The extension talks only to the NEFORUM app on your own computer (127.0.0.1). It sends nothing to NEFORUM's developers or anyone else, and has no analytics.
- It pairs with NEFORUM through a 6-digit code shown in the app.
- NEFORUM gives it one post at a time, only when you open a hand-off, and forgets it after 10 minutes.

After installing, click the NEFORUM button and choose "Allow on supported sites" so it can fill in pages.
```

**Categories**: Social & Communication; Photos, Music & Videos

**Tags**: social media, cross-post, mastodon, bluesky, scheduler

**Support email**: the maintainer's public address (not kept in the repository)

**Support website**: https://github.com/Neforuss/NEFORUM/issues

**Homepage**: https://neforus.com/neforum/

**License**: GNU General Public License v3.0

**Privacy policy**: link https://neforus.com/neforum/privacy/ , or paste:

```text
The NEFORUM extension collects no data. It communicates only with the NEFORUM desktop app on the same computer (http://127.0.0.1), from which it receives the post you chose to publish and to which it reports whether that post was filled in and posted. It stores one pairing token in the browser's extension storage. It sends nothing to NEFORUM's developers or any third party, uses no analytics, and loads no remote code.
```

**This add-on requires payment, non-free services or software**: No (NEFORUM is free and open source).

## Permissions, as AMO's reviewers see them

The manifest asks for these; the reviewer notes below explain them.

| Permission | Why |
|---|---|
| `storage` | Keeps the pairing token NEFORUM issued when the user typed the pairing code, so the extension stays paired after a restart. |
| `scripting` | "Fill in this page" injects the extension's own packaged scripts into the current tab, for sites whose address is not known in advance (the user's Mastodon server, a blog). |
| `activeTab` | Limits "Fill in this page" to the tab the user is on when they click the button. |
| `http://127.0.0.1/*` | The NEFORUM app on the same computer listens there (ports 52772-52779 or 41772-41779): the post to fill in, its photos and videos, and the report back. No other server. |
| Content scripts on the networks' sites | The networks NEFORUM hands posts to (listed in the manifest). The script fills in the post the user opened from NEFORUM and shows a small panel; it does nothing on a site unless NEFORUM has a post waiting for it. |

## Screenshots (1280 x 800)

The four `screenshot-*.png` in [extensions/browser/store/images](../extensions/browser/store/images), with these captions:

1. The toolbar popup, paired with NEFORUM.
2. The panel on a post the extension filled in: you check it, then press Post.
3. A NEFORUM hand-off: **Open** lets the extension fill in the site.
4. NEFORUM's **Settings > Browser extension**.

## Notes to reviewer

```text
This extension is the companion of NEFORUM, a free, open-source desktop cross-poster (GPL-3.0): https://github.com/Neforuss/NEFORUM. Without the NEFORUM app running on the same computer it does nothing.

Source code: the package contains the unminified, unbundled source (extensions/browser/src in the repository, plus manifest.firefox.json as manifest.json). No build step, transpiler or minifier is involved, so no separate source upload is needed. Built with: cd apps/neforum_app && dart run tool/build_extension.dart

Posting: the extension never presses a site's Post button by itself, except for jobs the user marked automatic: the user turned on "Post automatically" in the NEFORUM app, for that network (off by default; X, LinkedIn and Snapchat are left out unless the user adds them). Even then it shows a 3-second countdown that Stop or Esc cancels, asks the app again right before pressing, and presses only once, on the one page the app opened. Otherwise it posts only when the user presses Ctrl+Enter or clicks "Post now" in its panel; synthetic key events are ignored.

Network access: only http://127.0.0.1 (the NEFORUM app on this computer). Pairing needs a 6-digit code shown in the app; the app refuses requests from web pages. No analytics, no remote code, no other servers. data_collection_permissions: none.

How to test:
1. Install NEFORUM from https://neforus.com/neforum/ (Windows, macOS or Linux).
2. In NEFORUM: Settings > Browser extension > Pair a browser. Click the extension's toolbar button, type the code, and choose "Allow on supported sites".
3. Accounts > Add account > Bluesky > "Hand off to the app" > Add Bluesky (no keys or password; the handle is only a label).
4. Sign in to bsky.app in Firefox with any test account. Compose a post with a photo in NEFORUM, select the Bluesky account, Publish. In the hand-off, click Open: bsky.app opens and the extension fills the post in. Do not press Ctrl+Enter if you do not want to post.
(The demo workspace never sends posts to the extension.)
```

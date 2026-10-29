# Chrome Web Store listing (NEFORUM extension)

Ready-to-paste text for the Chrome Web Store developer dashboard (<https://chrome.google.com/webstore/devconsole>). Upload `neforum-extension-chrome-<version>.zip` from the GitHub release (or `dist/` after `dart run tool/build_extension.dart` in `apps/neforum_app`). The extension's id changes when it is published there; NEFORUM pairs with any id, so nothing in the app needs to change.

Account: a Chrome Web Store developer account (one-time US$5 registration fee), with a verified contact email.

## Store listing tab

**Name** (from the manifest): NEFORUM

**Summary** (from the manifest, 132 characters at most):

> Fills in NEFORUM hand-offs on each site (text, threads, polls, photos, videos, artwork). You post, or turn on automatic posting.

**Category**: Lifestyle > Social Networking

**Language**: English

**Description**:

```text
The companion extension of NEFORUM, the free and open-source cross-poster (https://neforus.com/neforum/). It needs the NEFORUM desktop app on the same computer (Windows, macOS or Linux).

NEFORUM writes one post for every network. Where a network has no open API, NEFORUM hands the finished post to you: a "hand-off". With this extension, a hand-off opens the network's own page and fills the post in for you:

- the text, and every part of a thread on X, Bluesky and Threads
- photos and videos, uploaded into the composer
- poll and quiz answers on YouTube Posts
- title, description, tags, age rating and AI options on art sites (Behance, ArtStation, Cara, pixiv, Itaku, Newgrounds, Fur Affinity, Weasyl, Ko-fi, Artfol, 500px, Dribbble, Flickr)
- TikTok Studio, Instagram, Facebook, LinkedIn, Pinterest, Reddit, Tumblr, Substack Notes, WhatsApp Web, Google Business Profile, Snapchat
- any other site (a blog, your Mastodon server): click the icon, then "Fill in this page"

You check the post and press Ctrl+Enter (Cmd+Enter on a Mac) or "Post now" in the extension's panel. If you turn on "Post automatically" in NEFORUM, the extension presses the site's Post button itself after a 3-second countdown you can stop, also for scheduled posts while NEFORUM runs. It stays off for X, LinkedIn and Snapchat unless you include them, because their terms forbid scripted posting.

Private by design:
- The extension talks only to the NEFORUM app on your own computer (127.0.0.1). It sends nothing to NEFORUM's developers or anyone else, and has no analytics.
- It pairs with NEFORUM through a 6-digit code shown in the app.
- NEFORUM gives it one post at a time, only when you open a hand-off, and forgets it after 10 minutes.

Free and open source (GPL-3.0): https://github.com/Neforuss/NEFORUM
Guide: https://github.com/Neforuss/NEFORUM/blob/main/docs/browser-extension.md
```

**Homepage URL**: https://neforus.com/neforum/

**Support URL**: https://github.com/Neforuss/NEFORUM/issues

**Graphics**:

All in [extensions/browser/store/images](../extensions/browser/store/images):

- Store icon: 128 x 128, `icon-128.png` (the same as the package's).
- Small promo tile: 440 x 280 (required), `promo-tile-440x280.png`.
- Marquee promo tile: 1400 x 560 (optional), `marquee-1400x560.png`.
- Screenshots: 1280 x 800, the four `screenshot-*.png` (see the list below).

## Privacy practices tab

**Single purpose**:

> Fill in posts that the user prepared in the NEFORUM desktop app on social networks' own web pages, so the user can publish them there.

**Permission justifications**:

| Permission | Justification to paste |
|---|---|
| `storage` | Keeps the pairing token that the NEFORUM app on this computer issued when the user typed the pairing code, so the extension stays paired across browser restarts. Nothing else is stored. |
| `scripting` | When the user clicks "Fill in this page" in the popup, injects the extension's own filling scripts into the current tab, for sites whose address is not known in advance (the user's Mastodon server, a blog). Only the extension's packaged files are injected; no remote code. |
| `activeTab` | Gives "Fill in this page" access to the one tab the user is on when they click the extension's button, instead of permanent access to every site. |
| Host permission `http://127.0.0.1/*` | The NEFORUM desktop app on the same computer listens on 127.0.0.1 (ports 52772-52779, or 41772-41779 when Windows reserves those). The extension asks it for the post to fill in, reads the post's photos and videos from it, and reports whether the post was filled in and posted. It never contacts any other server. |
| Content script matches (x.com, twitter.com, bsky.app, threads.com/.net, linkedin.com, facebook.com, youtube.com, studio.youtube.com, substack.com, tiktok.com, instagram.com, pinterest.com, reddit.com, tumblr.com, web.whatsapp.com, business.google.com, snapchat.com, behance.net, artstation.com, cara.app, pixiv.net, itaku.ee, newgrounds.com, furaffinity.net, weasyl.com, ko-fi.com, artfol.app, 500px.com, dribbble.com, flickr.com) | These are the networks NEFORUM hands posts to. On their composer and upload pages the script fills in the post that the user opened from NEFORUM (text, media, tags, poll answers) and shows a small panel with what was filled in. On these sites it does nothing unless NEFORUM has a post waiting for that site. It reads only what it needs to find the composer, its fields and the Post button. |

**Are you using remote code?** No. All JavaScript is in the package (no `eval`, no remotely hosted scripts, no bundler output).

**Data usage**: the extension does not collect user data: nothing it handles leaves the computer. It moves the user's own post from the NEFORUM app on 127.0.0.1 into the page the user opened, and tells that app whether it was filled in and posted. Leave every data type unchecked.

If a reviewer asks for a declaration anyway, the conservative answer is **Website content** and **Personal communications** (the post being published), both "handled on the device only, never transmitted to the developer or third parties".

**Certifications** (tick all three):

- I do not sell or transfer user data to third parties, outside of the approved use cases.
- I do not use or transfer user data for purposes that are unrelated to my item's single purpose.
- I do not use or transfer user data to determine creditworthiness or for lending purposes.

**Privacy policy URL**: https://neforus.com/neforum/privacy/

## Screenshots (1280 x 800)

1. `screenshot-1-popup.png`: the popup, paired with NEFORUM, with "Fill in this page".
2. `screenshot-2-panel.png`: the extension's panel on a composer it filled in: what went in, **Post now** (Ctrl+Enter), and the thread's other parts to add.
3. `screenshot-3-handoff.png`: a NEFORUM hand-off, whose **Open** button the extension takes over.
4. `screenshot-4-settings.png`: NEFORUM's **Settings > Browser extension**: install, pair, **Post with Ctrl+Enter**.

The pictures of the popup and the panel are the extension's own files (popup.html, panel.js) on a neutral demo page, made as described in [extensions/browser/store](../extensions/browser/store).

## Distribution tab

- Visibility: Public.
- Regions: all.
- Pricing: free.

## Notes for the reviewer

```text
This extension is the companion of NEFORUM, a free, open-source desktop cross-poster (GPL-3.0): https://github.com/Neforuss/NEFORUM. Without the NEFORUM app running on the same computer it does nothing.

What it does: NEFORUM prepares a post; when a network has no usable API, the user opens a "hand-off" and the extension fills the post into that network's own composer page (text, media, tags, poll answers).

Posting: the extension never presses a site's Post button by itself, except for jobs the user marked automatic: the user turned on "Post automatically" in the NEFORUM app, for that network (off by default; X, LinkedIn and Snapchat are left out unless the user adds them). Even then it shows a 3-second countdown that Stop or Esc cancels, asks the app again right before pressing, and presses only once, on the one page the app opened. Otherwise it posts only when the user presses Ctrl+Enter / Cmd+Enter or clicks "Post now" in its panel; synthetic key events are ignored.

Network access: only http://127.0.0.1 (the NEFORUM app on this computer, ports 52772-52779 or 41772-41779). Pairing needs a 6-digit code shown in the app; the app refuses requests from web pages. No analytics, no remote code, no other servers.

How to test:
1. Install NEFORUM from https://neforus.com/neforum/ (Windows, macOS or Linux).
2. In NEFORUM: Settings > Browser extension > Pair a browser. Click the extension's icon and type the code.
3. Accounts > Add account > Bluesky > "Hand off to the app" > Add Bluesky (no keys or password; the handle is only a label).
4. Sign in to bsky.app in this browser with any test account. Compose a post with a photo in NEFORUM, select the Bluesky account, Publish. In the hand-off, click Open: bsky.app opens and the extension fills the post in. Do not press Ctrl+Enter if you do not want to post.
(The demo workspace never sends posts to the extension.)

Source code: the packaged files are the unminified source in extensions/browser/src of the repository.
```

# Parler setup guide

This guide connects Parler by **hand-off only**: NEFORUM copies your post and opens Parler's composer, and you paste it and click **Post**. With the NEFORUM browser extension paired, the composer is filled in for you. Nothing to set up, no API key, no sign-in.

## Steps

1. In NEFORUM, add an account and choose **Parler**.
2. Optionally type a label, for example your Parler handle.
3. If the account has **Parler Premium**, turn on **Parler Premium**: posts can then be 2000 characters instead of 300.
4. Tap **Add Parler**. That's it.

## Steps: when you publish

1. Publish your post. NEFORUM copies your text to the clipboard and opens Parler's composer, <https://app.parler.com/compose>. Sign in there once if you are not signed in yet.
2. Click **What's on your mind?** and press Ctrl+V (⌘V on a Mac) to paste your text.
3. To add photos or a video, click **Save media to Downloads** in NEFORUM, then **Attach media** in Parler and pick them. You can also drag them in or paste them.
4. Click **Post**.

## Steps: with the browser extension

1. Pair the NEFORUM browser extension once: Settings > Browser extension.
2. Publish your post. NEFORUM opens Parler's composer in that browser, and the extension types your text and adds your photos and videos.
3. Check the post and click **Post** (or press Ctrl+Enter).
4. To have the extension press **Post** itself, turn on **Post automatically** in Settings > Browser extension. It is off by default and waits three seconds, which you can stop.

## Ways to connect

Status as of November 2026.

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Hand-off** (only tier) | Any Parler account | Free | NEFORUM copies your post and opens Parler's composer. You paste it, or the browser extension fills it in, and you click **Post**. |

## How it works

### Why there is no automatic posting through an API

- Parler publishes **no API for posting**.
- The unofficial client parler-py-api was archived on 2026-03-08. NEFORUM never used it and never asks for your Parler login.
- Parler documents no link that fills in its composer (`/compose` only opens it), so the text goes on the clipboard, or the browser extension types it in.

### Parler's terms

Parler's Terms of Service (last modified 2026-04-28) forbid reaching the service "through automated means in a manner that puts excessive demand on the Services". The extension fills in one post that you started, in your own browser, as you would.

## Limits

These were read from Parler's web composer and the code it loads on 2026-11-13. Parler's help centre states none of them, so they may change without notice.

- Text: **300 characters** on a free account, **2000** with Parler Premium. Each character counts as one, emoji included. The composer shows how many are left.
- Up to **4 photos, GIFs and videos per post, together**.
- Photos: JPEG, PNG, GIF and WebP, up to **20 MB** each.
- Videos: MP4, MOV and WebM, up to **500 MB** and **60 minutes**. ParlerPlay (Parler's video site) takes uploads up to 10 GB; that is a separate upload page.
- A sound file goes as a video of one still picture, made by NEFORUM.
- Parler has no threads in NEFORUM: a thread is joined into one post.

### Known limitations

- NEFORUM does not know the Parler Android app's package, so on a phone the composer opens in your browser.
- Bursts and Stories (the composer's other tabs) are not filled in.

## Sources

- Parler Terms of Service: https://parler.com/terms-of-service
- Parler help centre, Posting: https://parler-support.zendesk.com/hc/en-us/articles/32103922111508-Posting
- Parler help centre, ParlerPlay FAQ (10 GB uploads): https://parler-support.zendesk.com/hc/en-us/articles/32152075767060
- Parler's web composer: https://app.parler.com/compose

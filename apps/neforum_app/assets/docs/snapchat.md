# Snapchat setup guide

This guide connects Snapchat by **hand-off only**: your photo or video opens in Snapchat, you paste the caption and send it to **My Story**, **Spotlight** or friends. Nothing to set up, no developer app, no sign-in.

## Steps

1. In NEFORUM, add an account and choose **Snapchat**.
2. Optionally type a label (for example your username).
3. Tap **Add Snapchat**. That's it.

## Steps: when you publish

1. Publish your post. NEFORUM copies your caption to the clipboard and opens the share sheet with your photo or video.
2. Pick **Snapchat**. The file opens in Snapchat's editor.
3. Tap the text tool (**T**) and paste your caption.
4. Tap **Send To**.
5. Choose **My Story**, **Spotlight** or friends, and send.

On a computer, NEFORUM opens [Snapchat for Web](https://www.snapchat.com/web/). Posting Stories from a computer is limited, so use the phone app.

## Ways to connect

Status as of October 2026.

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Hand-off** (only tier) | Any Snapchat account and the Snapchat app on your phone | Free | Your photo or video opens in Snapchat. You paste the caption, choose **My Story**, **Spotlight** or friends, and send. |

## How it works

**Only media can be handed over.** Snapchat ignores text that comes with shared files, which is why your caption is on the clipboard. A Snapchat post always needs a photo or video, so NEFORUM shows an error for text-only posts.

### Why there is no automatic posting

- Snapchat's posting API, the **Public Profile API**, is part of the Snap Marketing API. It lets *approved partners* post for **brands and creators** with Public Profiles. It is not open to personal accounts or to a free app that anyone can install.
- **Creative Kit** (Snap Kit) never posts by itself. It only opens Snapchat's own editor, and the user still taps Send. To pass a caption or sticker it also needs a Snap Kit **Client ID** for an app that Snap reviews ("All integrations are subject to our review and approval"). NEFORUM is open source and cannot ship a shared Client ID, so it uses the normal system share sheet.

## Limits

From the Snap Creative Kit documentation:

- Caption: up to **250 characters** ("Captions are limited to 250 characters").
- One photo **or** one video per share.
- Photos: PNG or JPEG. Videos: MP4 or MOV.
- Up to **300 MB**. Videos up to **5 minutes**; Snapchat splits anything over 10 seconds into several Snaps.
- Use vertical **9:16** media. Wider pictures are cropped or get bars; NEFORUM shows a hint.
- No alt text, no threads, no scheduling.

### Known limitations

- Captions cannot be prefilled: you paste them yourself.
- NEFORUM cannot choose My Story, Spotlight or friends for you.
- The 250-character limit comes from Creative Kit. Snapchat does not say how it counts characters, so NEFORUM counts them as most apps do (UTF-16).

## Sources

- Creative Kit overview (limits): https://developers.snap.com/snap-kit/creative-kit/overview
- Creative Kit Web: https://developers.snap.com/snap-kit/creative-kit/web
- Creative Kit Lite sample (package `com.snapchat.android`, Client ID requirement): https://github.com/Snapchat/creative-kit
- Snap Kit app review: https://developers.snap.com/snap-kit/app-review/overview
- Public Profile API: https://developers.snap.com/api/marketing-api/Public-Profile-API/Introduction

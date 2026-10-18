# Odysee

NEFORUM can upload to Odysee (the LBRY network) **automatically** on a computer, through the LBRY desktop app, or by **hand-off** anywhere.

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Auto** | The LBRY desktop app on the same computer, signed in with your Odysee account, and a little LBC | A deposit of 0.001 LBC per upload (returned if you remove the video) plus a tiny network fee | NEFORUM publishes the video in your channel itself. Any file size. |
| **Hand-off** | Any Odysee account | Free | odysee.com's upload page opens with your title, description and tags ready to paste (web uploads up to 4 GB). |

Status as of October 2026.

## How the automatic tier works

Odysee runs on LBRY, whose software (the **LBRY SDK**, `lbrynet`) is open source and has a documented JSON-RPC API. The LBRY desktop app runs the SDK on your computer at `http://localhost:5279`. NEFORUM asks it to `publish` your video: the SDK reads the file straight from disk (so large videos are fine), creates the claim in your channel and starts sending the video to the network. **Keep the LBRY app open** until the video plays on odysee.com: it uploads in the background.

## Set up the automatic tier

1. Install the LBRY desktop app from <https://lbry.com/get> and open it.
2. Sign in with your **Odysee account**, so the app's wallet holds your channel (it syncs with Odysee).
3. Make sure the wallet has a little **LBC**. Each upload locks a deposit (0.001 LBC by default), which comes back if you remove the video.
4. In NEFORUM, add an account, open **Video sites**, choose **Odysee**, then **Auto**.
5. Enter your **channel** (for example `@mychannel`). Leave it empty to publish without a channel. Click **Connect**: NEFORUM checks that the LBRY app is running and that the channel is in its wallet.

## What happens when you publish

- The post's **title** becomes the video title (without one, NEFORUM uses the first line of the text), the text becomes the description, and up to five tags are added.
- The claim name is made from the title plus a short random suffix (for example `my-first-video-3f9a1c`), so a new upload never replaces an older one.
- When the SDK has accepted the upload, NEFORUM links to `https://odysee.com/<name>:<claim id>`.

If the LBRY app is closed, the upload fails with "The LBRY app is not running"; open it and publish again. If the wallet has too little LBC, NEFORUM says so.

## Hand-off

NEFORUM opens <https://odysee.com/$/upload> and puts the description on the clipboard. Click **Save media to Downloads** in the hand-off window, pick the video on Odysee, copy the **Title** and **Tags**, choose your channel and publish.

## Notes

- Thumbnails: add or change one on Odysee after publishing if you want your own.
- The automatic tier works on Windows, macOS and Linux (where the LBRY app runs). On phones, use hand-off.
- Sources: LBRY SDK API (`publish`, `channel_list`, `status`): <https://lbry.tech/api/sdk>. Odysee upload page: <https://odysee.com/$/upload>.

# Odysee setup guide

This guide connects Odysee (the LBRY network), so NEFORUM uploads your videos **automatically** on a computer, through the LBRY desktop app, or by **hand-off** anywhere.

## Steps

1. Install the LBRY desktop app from <https://lbry.com/get>.
2. Open the LBRY app.
3. Sign in with your **Odysee account**, so the app's wallet holds your channel (it syncs with Odysee).
4. Make sure the wallet has a little **LBC**.
   - Each upload locks a deposit (0.001 LBC by default), which comes back if you remove the video.
5. In NEFORUM, add an account, open **Video sites**, choose **Odysee**, then **Auto**.
6. Enter your **channel**, for example `@mychannel`.
   - Leave it empty to publish without a channel.
7. Click **Connect**. NEFORUM checks that the LBRY app is running and that the channel is in its wallet.
8. When you publish, **keep the LBRY app open** until the video plays on odysee.com: it uploads in the background.

## Steps: hand-off

1. In NEFORUM, add an account, open **Video sites**, choose **Odysee**, then **Hand-off**.
2. Publish your post. NEFORUM opens <https://odysee.com/$/upload> and puts the description on the clipboard.
3. Click **Save media to Downloads** in the hand-off window.
4. Pick the video on Odysee.
5. Copy the **Title** and **Tags** from the hand-off window into Odysee's fields.
6. Choose your channel.
7. Publish.

## Ways to connect

Status as of October 2026.

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Auto** | The LBRY desktop app on the same computer, signed in with your Odysee account, and a little LBC | A deposit of 0.001 LBC per upload (returned if you remove the video) plus a tiny network fee | NEFORUM publishes the video in your channel itself. Any file size. |
| **Hand-off** | Any Odysee account | Free | odysee.com's upload page opens with your title, description and tags ready to paste (web uploads up to 4 GB). |

The automatic tier works on Windows, macOS and Linux (where the LBRY app runs). On phones, use hand-off.

## How it works

Odysee runs on LBRY, whose software (the **LBRY SDK**, `lbrynet`) is open source and has a documented JSON-RPC API. The LBRY desktop app runs the SDK on your computer at `http://localhost:5279`. NEFORUM asks it to `publish` your video: the SDK reads the file straight from disk (so large videos are fine), creates the claim in your channel and starts sending the video to the network. Keep the LBRY app open until the video plays on odysee.com.

### What happens when you publish

- The post's **title** becomes the video title (without one, NEFORUM uses the first line of the text), the text becomes the description, and up to five tags are added.
- The claim name is made from the title plus a short random suffix (for example `my-first-video-3f9a1c`), so a new upload never replaces an older one.
- When the SDK has accepted the upload, NEFORUM links to `https://odysee.com/<name>:<claim id>`.
- Thumbnails: add or change one on Odysee after publishing if you want your own.

## Troubleshooting

- **"The LBRY app is not running"**: the LBRY app is closed. Open it and publish again.
- **Too little LBC**: if the wallet has too little LBC, NEFORUM says so. Add LBC to the wallet.

## Sources

- LBRY SDK API (`publish`, `channel_list`, `status`): <https://lbry.tech/api/sdk>
- Odysee upload page: <https://odysee.com/$/upload>

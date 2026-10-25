# YouTube Posts setup guide

This guide connects **YouTube Posts**, the text, image, poll and quiz posts on your channel's **Posts** tab (called the Community tab until 2025; for videos and Shorts, connect **YouTube** instead, you can have both). NEFORUM copies your text and opens YouTube for you to post; on a computer with the NEFORUM browser extension, it can also post for you automatically once you turn that on.

## Steps

1. In NEFORUM, add an account and choose **YouTube Posts**.
2. Type your channel handle (`@yourchannel`) or channel link.
   - Recommended: NEFORUM then opens your channel's **Posts** tab, where the post box is.
3. Optionally type a label.
4. Tap **Add YouTube Posts**. That's it.

## Steps: post automatically from a computer

Automatic posting is off until you turn it on, and works only on a computer with the browser extension.

1. Install the NEFORUM browser extension and pair it with NEFORUM (see the [browser extension guide](../browser-extension.md)).
2. Sign in to YouTube in the paired browser.
3. In NEFORUM, open **Settings > Browser extension** and turn on **Post automatically**.
4. Check that **YouTube Posts** is among the networks that post automatically there (it is unless you excluded it).
5. Publish your post. NEFORUM opens your channel's **Posts** tab in the browser by itself, the extension fills in the post and, after a 3-second countdown, presses **Post**.
6. To stop a post, click **Stop** in the extension's panel before the countdown ends.

## Steps: when you publish (manual hand-off)

These steps apply on phones, and on computers without the extension or with automatic posting off.

1. Publish your post. NEFORUM copies your text to the clipboard and opens your channel's Posts tab, for example `https://www.youtube.com/@yourchannel/posts`.
   - Without a channel it opens youtube.com; on a phone, the YouTube app.
2. Click the post box at the top of the Posts tab (or **Create** > **Create post**).
   - In the app, tap **+** (Create), then **Post**.
3. Press Ctrl+V (⌘V on a Mac) to paste your text.
4. To add images, choose the image option:
   - On a computer, copy each image with its button in NEFORUM and paste it if the post box takes pasted images, or use **Save media to Downloads** (it saves them with clear names and opens the folder) and drag them in.
   - On a phone, tap **Share with media** first and save the images to your photos.
5. For a poll or quiz, choose the poll or quiz option under the text box and paste each answer, caption and the explanation with its **Copy** button, in order.
6. Select **Post**, or the arrow next to it and **Schedule post** to let YouTube publish it later.

If you schedule the post in NEFORUM, it reminds you at the scheduled time (with automatic posting on, NEFORUM posts it instead; see *Automatic posting*).

## Ways to connect

YouTube Posts are YouTube's version of a tweet, separate from videos and Shorts.

Status as of October 2026.

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Hand-off** (only tier) | A YouTube channel with advanced features turned on, not set as Made for Kids | Free | NEFORUM copies your text and opens YouTube. You choose **Create** > **Create post**, paste and select **Post**. On a computer with the browser extension and **Post automatically** turned on, the extension posts it for you. |

Nothing to set up for the hand-off itself: no API key, no sign-in in NEFORUM.

## How it works

### Automatic posting

- It works only on a computer (Windows, macOS or Linux) with a paired browser, and only after you turn on **Settings > Browser extension > Post automatically** (off by default). On phones you always finish the post yourself.
- When you publish, the hand-off opens your channel's Posts tab in the paired browser without a click. The extension fills in everything: the text, the poll or quiz answers, and the images. It then shows a 3-second countdown in its panel, with **Stop**, presses YouTube's **Post** button and checks that the post went out. NEFORUM marks the post as handed off and moves on to the next hand-off.
- The extension presses **Post** only for posts NEFORUM marks automatic, which only happens when you turned automatic posting on.
- **Scheduled posts:** while NEFORUM runs on a computer with automatic posting on and a paired browser, YouTube Posts that are due are posted the same way, without the hand-off window. If that fails, the post waits for you with the usual reminder.
- **If any step fails** (for example YouTube changed its page), the extension stops and leaves the page filled in for you, and the hand-off window falls back to the manual steps.
- With a paired browser and automatic posting off, the extension still fills in the post when you open the hand-off; you check it and post it yourself.
- The click on **Post** is still made by the extension, and some platforms count scripted clicks as automation. If you'd rather press Post yourself, leave **Post automatically** off.

### Why there is no posting through YouTube's API

- The **YouTube Data API cannot create posts**. Its resources cover videos, playlists, comments, captions and channel settings, and its revision history (latest entry 30 September 2026) adds nothing for posts. On 30 April 2024 it also dropped what was left of channel posting: "The API no longer supports the ability to insert or retrieve channel discussions."
- Tools that schedule YouTube posts automatically drive YouTube's private web API with your login cookies. YouTube's terms forbid that, it can get a channel flagged, and it breaks whenever YouTube changes its site. NEFORUM does not do it: the browser extension fills in YouTube's own post box in your browser.
- YouTube has no link that opens a prefilled post, so in the manual hand-off the text goes via the clipboard.

### Who can post

- Your channel needs **advanced features**: YouTube Studio > **Settings** > **Channel** > **Feature eligibility**. Most established channels qualify automatically; newer ones can verify with video verification or an ID. After turning it on, the Posts tab can take up to 48 hours to appear.
- There is **no subscriber minimum** any more (older guides mention 500 or 1,000).
- Channels set as **Made for Kids** cannot create posts, and supervised accounts cannot either.
- YouTube limits how many posts a channel can make in 24 hours (it does not say how many). If YouTube says "limit reached", try again the next day.

## Limits

From YouTube Help, "Create a post":

- Up to **10 images or GIFs** per post. JPG, PNG, GIF or WEBP, up to 16 MB each. Square (1:1) images show best in the feed.
- Posts **cannot upload a video**. A video post points at an existing YouTube video: paste its link.
- **Polls and quizzes:** add them in NEFORUM's composer with the **Poll** button; the post text is the question.
  - Text poll: 2 to 4 answers, each within 65 characters.
  - Image poll: 2 to 4 of the post's images, each with a caption within 36 characters.
  - Quiz: 2 to 4 answers of up to 80 characters, exactly one correct, and an optional explanation of up to 500 characters.
  - A poll or quiz post cannot also carry images (except an image poll, whose images are the answers), so NEFORUM leaves the images out for YouTube and says so.
  - In the manual hand-off, the question is on the clipboard and every answer, caption and the explanation has its own **Copy** button. In YouTube choose the poll or quiz option under the text box and paste them in order.
  - Other networks get the same post without the poll.
- YouTube publishes **no length limit** for text. Viewers see about the first 280 characters before **Read more**, so NEFORUM shows a note for longer posts.
- Mention another channel with @ and its handle. Hashtags work as on the rest of YouTube.

### Known limitations

- Without automatic posting, you always paste the text and add images yourself.
- The YouTube app does not document a share target for images, so NEFORUM's share sheet is for saving the images, not for opening a post directly.

## Sources

- YouTube Help, Create a post (steps, 10 images, 16 MB, poll limits, daily limit): https://support.google.com/youtube/answer/7124474
- YouTube Help, feature access and advanced features: https://support.google.com/youtube/answer/9890437
- YouTube Data API reference (no posts resource): https://developers.google.com/youtube/v3/docs
- YouTube Data API revision history (30 April 2024: channel discussions removed): https://developers.google.com/youtube/v3/revision_history

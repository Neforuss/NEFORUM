# YouTube Posts

**YouTube Posts** are the text, image, poll and quiz posts on your channel's **Posts** tab (called the Community tab until 2025): YouTube's version of a tweet. They are separate from videos and Shorts. For videos, connect **YouTube** in NEFORUM instead; you can have both.

NEFORUM reaches YouTube Posts by **hand-off only**. Nothing to set up, no API key, no sign-in.

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Hand-off** (only tier) | A YouTube channel with advanced features turned on, not set as Made for Kids | Free | NEFORUM copies your text and opens YouTube. You choose **Create** > **Create post**, paste and select **Post**. |

Status as of October 2026.

## Why there is no automatic posting

- The **YouTube Data API cannot create posts**. Its resources cover videos, playlists, comments, captions and channel settings, and its revision history (latest entry 30 September 2026) adds nothing for posts. On 30 April 2024 it also dropped what was left of channel posting: "The API no longer supports the ability to insert or retrieve channel discussions."
- Tools that schedule YouTube posts automatically drive YouTube's private web API with your login cookies. YouTube's terms forbid that, it can get a channel flagged, and it breaks whenever YouTube changes its site. NEFORUM does not do it.
- YouTube has no link that opens a prefilled post, so the text goes via the clipboard.

## Who can post

- Your channel needs **advanced features**: YouTube Studio > **Settings** > **Channel** > **Feature eligibility**. Most established channels qualify automatically; newer ones can verify with video verification or an ID. After turning it on, the Posts tab can take up to 48 hours to appear.
- There is **no subscriber minimum** any more (older guides mention 500 or 1,000).
- Channels set as **Made for Kids** cannot create posts, and supervised accounts cannot either.
- YouTube limits how many posts a channel can make in 24 hours (it does not say how many). If YouTube says "limit reached", try again the next day.

## Setting it up

1. In NEFORUM, add an account and choose **YouTube Posts**.
2. Optionally type your channel handle (`@yourchannel`) or channel link, so NEFORUM shows which channel this is, and a label. Tap **Connect**. That's it.

## What happens when you publish

1. NEFORUM copies your text to the clipboard and opens youtube.com (on a phone: the YouTube app).
2. Select **Create** > **Create post** at the top of the page. In the app, tap **+** (Create), then **Post**.
3. Paste your text. To add images, choose the image option. On a computer, **Save media to Downloads** in NEFORUM saves them with clear names and opens the folder so you can drag them in; on a phone, tap **Share with media** first and save the images to your photos.
4. Select **Post**, or the arrow next to it and **Schedule post** to let YouTube publish it later.

If you schedule the post in NEFORUM, it reminds you at the scheduled time.

## Limits

From YouTube Help, "Create a post":

- Up to **10 images or GIFs** per post. JPG, PNG, GIF or WEBP, up to 16 MB each. Square (1:1) images show best in the feed.
- Posts **cannot upload a video**. A video post points at an existing YouTube video: paste its link.
- **Polls and quizzes:** add them in NEFORUM's composer with the **Poll** button; the post text is the question.
  - Text poll: 2 to 4 answers, each within 65 characters.
  - Image poll: 2 to 4 of the post's images, each with a caption within 36 characters.
  - Quiz: 2 to 4 answers of up to 80 characters, exactly one correct, and an optional explanation of up to 500 characters.
  - A poll or quiz post cannot also carry images (except an image poll, whose images are the answers), so NEFORUM leaves the images out for YouTube and says so.
  - In the hand-off, the question is on the clipboard and every answer, caption and the explanation has its own **Copy** button. In YouTube choose the poll or quiz option under the text box and paste them in order.
  - Other networks get the same post without the poll.
- YouTube publishes **no length limit** for text. Viewers see about the first 280 characters before **Read more**, so NEFORUM shows a note for longer posts.
- Mention another channel with @ and its handle. Hashtags work as on the rest of YouTube.

## Known limitations

- You always paste the text and add images yourself.
- The YouTube app does not document a share target for images, so NEFORUM's share sheet is for saving the images, not for opening a post directly.

## Sources

- YouTube Help, Create a post (steps, 10 images, 16 MB, poll limits, daily limit): https://support.google.com/youtube/answer/7124474
- YouTube Help, feature access and advanced features: https://support.google.com/youtube/answer/9890437
- YouTube Data API reference (no posts resource): https://developers.google.com/youtube/v3/docs
- YouTube Data API revision history (30 April 2024: channel discussions removed): https://developers.google.com/youtube/v3/revision_history

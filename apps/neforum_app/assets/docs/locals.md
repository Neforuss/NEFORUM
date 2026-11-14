# Locals setup guide

This guide connects Locals (locals.com) by **hand-off only**: NEFORUM copies your post and opens your community's feed on Locals, and you paste it and click **Publish**. With the NEFORUM browser extension paired, the post is filled in for you. Nothing to set up, no API key, no sign-in.

## Steps

1. In NEFORUM, add an account and choose **Locals**.
2. Optionally type a label, for example your Locals name.
3. Under **Community**, enter the community you post in, as in its address: for `locals.com/name`, enter `name`. You can also paste a link to it (`https://locals.com/name/feed`) or its older address `name.locals.com`. Leave it empty to open your Locals news feed instead.
4. Tap **Add Locals**. That's it.

## Steps: with the browser extension

1. Pair the NEFORUM browser extension once: Settings > Browser extension.
2. Publish your post. NEFORUM opens your community's feed (`https://locals.com/name/feed`) in that browser. The extension clicks **Regular Post**, types the title (when your post has one) and the text, and adds your photos.
3. A video or sound file cannot be added for you: the panel on the page says so. Click **Save media to Downloads** in NEFORUM, then the video (or sound) button under the post on Locals and pick the file, or drag it in.
4. Check the post and click **Publish** (or press Ctrl+Enter). If a file is still uploading, Ctrl+Enter waits for the upload to end.

## Steps: when you publish without the extension

1. Publish your post. NEFORUM copies your text to the clipboard and opens your community's feed (or the news feed, <https://locals.com/_/feed>, when you left the community empty: open your community from there). Sign in there once if you are not signed in yet.
2. Click **Regular Post** and press Ctrl+V (⌘V on a Mac) in the post to paste your text.
   - In the Locals app, open **My Communities**, tap **+** and pick the community.
3. If your post has a title, copy it from NEFORUM's hand-off into **Title:**.
4. To add photos, a video or a sound file, click **Save media to Downloads** in NEFORUM, then pick them with the buttons under the post on Locals. Keep the page open until the upload ends.
5. Click **Publish**.

## Ways to connect

Status as of November 2026.

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Hand-off** (only tier) | A Locals account that can post in a community: its creator or team, or a supporter where the community lets members post | Free | NEFORUM copies your post and opens your community's feed. You paste it, or the browser extension fills it in, and you click **Publish**. |

## How it works

### Why there is no automatic posting

- Locals publishes **no API for posting**.
- The post is written in a window on your community's feed (`locals.com/name/feed`): **Regular Post** opens it. Locals' news feed (`locals.com/_/feed`) shows the communities you follow and has no such window, so NEFORUM needs your community to open the right page.
- The browser extension fills that window in, but it does not press **Publish** for you even with **Post automatically** on: NEFORUM could not check Locals' terms on scripted posting, so Locals is not among the networks that post automatically. You press **Publish**.
- The extension leaves **Post Settings** as Locals sets them, **Only for Supporters** included.

### Who can post

Locals says: "Only supporters can leave posts or comments in communities that have them enabled." The creator and team post in their own community; a member who does not support it cannot post there.

## Limits

These were read from Locals' post window and the community settings it loads, signed in, on 2026-11-13. Locals' help centre states few of them, so they may change without notice.

- Text: up to **15,000 characters** (the counter under the post), plain text: no bold, links or lists. The Locals app keeps **Publish** greyed out below **10 characters**.
- Title: optional, up to **255 characters**.
- One kind of media per post: up to **10 photos** (JPEG, PNG, GIF and WebP, up to **20 MB** each), **or** one video, **or** one sound file (MP3, M4A, WAV), **or** one PDF. NEFORUM does not send PDFs.
- The photo limit is set per community: another community showed **5**. NEFORUM warns when a post has more than 5 photos.
- Videos: MPEG, MP4, Ogg, MOV, WebM, WMV, FLV, AVI, M4V, 3GP and 3G2. Members: videos and sound up to **5 minutes** and under **200 MB** (help centre). Creators and their team: by the community's plan (the community seen allowed 5 GB a file, and 5 GB of uploads a month on the Basic plan). NEFORUM warns above the member limit and lets a creator go ahead.
- Articles (a title of at least 5 characters, an optional subtitle and a JPEG, PNG or GIF cover, up to 60,000 characters) are a separate kind of post that you write on Locals. NEFORUM hands off ordinary posts.
- Locals has no threads: a thread is joined into one post.

### Known limitations

- A video, sound file or PDF goes into a Locals post only through its own buttons, which open the file window at once, so the extension cannot add one for you: it says so, and you pick or drag the file in. Photos go in by themselves.
- Large uploads need the Locals page kept open until they finish. Locals' **Auto-Submit Post** switch publishes the post when the upload ends.
- The Android app is `com.locals.localsapp` (linked from locals.com), but Locals does not document a share target, so NEFORUM does not share files to it.

## Sources

- What are tiers and what does upgrading my community plan entail?: https://support.locals.com/en/article/what-are-tiers-and-what-does-upgrading-my-community-plan-entail-q1555u/
- How do I upload videos, podcasts and photos?: https://support.locals.com/en/article/how-do-i-upload-videos-podcasts-photos-r49es4/
- How do I leave a post on the Locals app?: https://support.locals.com/en/article/how-do-i-leave-a-post-on-the-locals-app-8uy5p2
- How can I publish an article?: https://support.locals.com/en/article/how-can-i-publish-an-article-1nwqgql/

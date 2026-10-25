# Tumblr setup guide

This guide connects **any of your Tumblr blogs**, both your main blog and side blogs, so NEFORUM posts there automatically with your own free Tumblr app, or prepares the post for you to click **Post now** (hand-off).

## Steps

These steps set up "Your own API keys". Registering the app takes about a minute.

1. Sign in to Tumblr in your browser and open <https://www.tumblr.com/oauth/apps>.
2. Click **Register application**.
3. Fill in:
   - **Application Name**: anything, e.g. `NEFORUM for Ada`.
   - **Application Website**: any web address, for example `https://github.com/Neforuss/NEFORUM`.
   - **Application Description**: e.g. `Posting from my own NEFORUM app`.
   - **Administrative contact email**: your e-mail address.
   - **Default callback URL**:

     ```
     http://localhost:52771/callback
     ```

   - **OAuth2 redirect URLs** (space separated). Enter both addresses on one line:

     ```
     http://localhost:52771/callback neforum://callback/
     ```

     The first one is for NEFORUM on Windows and macOS, the second for Android and iPhone. **Keep the slash at the end of `neforum://callback/`**: Tumblr only accepts app addresses like this one when they end in a slash. Each address must match exactly, character for character. Use `localhost`, not `127.0.0.1`: Tumblr refuses to save `127.0.0.1` addresses.
4. Click **Register**. Tumblr only switches on OAuth 2 for an app once it has at least one OAuth2 redirect URL.
5. On the app list, copy the **OAuth Consumer Key**.
6. Click **Show secret key** and copy the **Secret Key** too.
7. In NEFORUM go to **Accounts > Add > Tumblr > Your own API keys** and paste both keys.
   - Leave **Redirect URI (advanced)** empty.
8. Optionally fill in **Blog name**: the blog to post to, i.e. the part before `.tumblr.com`.
   - Leave it empty to use your main blog.
   - To post to several blogs, add one NEFORUM account per blog. They can all use the same keys.
9. Click **Connect**. Your browser opens Tumblr's permission page.
10. Click **Allow**. NEFORUM asks for `basic` (read your blog list), `write` (create posts) and `offline_access` (stay signed in).

## Steps: stay connected on several devices (OAuth 1.0a keys)

Use these keys when the same blog is on more than one device: they are never renewed, so one device cannot cancel another's sign-in (see *Why OAuth 1.0a keys* below).

1. Register your Tumblr app as described in *Steps* (steps 1 to 6).
2. Signed in to Tumblr, open <https://api.tumblr.com/console>.
3. When it asks for a Consumer Key and Consumer Secret, paste your app's **OAuth Consumer Key** and **Secret Key**.
4. Click **Authenticate**.
5. Tumblr asks whether your app may use your account. Click **Allow**; you come back to the console.
6. Click **Show keys**. The console lists Consumer Key, Consumer Secret, **Token** and **Token Secret**.
   - The code examples in the console show the same four values.
7. In NEFORUM go to **Accounts > Add > Tumblr > Your own API keys**.
8. Paste the OAuth Consumer Key and Secret Key as usual.
9. Paste **Token** into **OAuth Token** and **Token Secret** into **OAuth Token Secret**.
10. Fill in **Blog name** if you want a side blog.
11. Click **Connect**. No browser sign-in opens: NEFORUM lists your blogs with the keys to check them. **Redirect URI (advanced)** is not used.
12. On every other device, paste the same four keys, or copy the account with **Settings → Move to another device**. It stays connected on all of them.

## Steps: hand-off (without API keys)

1. In NEFORUM go to **Accounts > Add > Tumblr > Hand-off**. No other setup is needed.
2. When you publish, check the post in the Tumblr page NEFORUM opens (see *Hand-off* below for which page opens).
   - Your text (title, text and link) is always on the clipboard too.
   - Values that go into separate fields (tags, alt text) are listed in the hand-off window so you can copy them one by one.
3. Click **Post now**.

## Steps: quote, chat and audio posts

NEFORUM picks text, photo, video or link posts by itself. For the other kinds:

1. In the composer, open the post's **Customize for Tumblr** (the sliders button next to Tumblr).
2. Choose **Post type**: **Quote**, **Chat** or **Audio**.
3. Write the post as the table under *Quote, chat and audio posts* below shows.

## Ways to connect

| Tier | What you need | Cost | Limits | Review |
|---|---|---|---|---|
| **Your own API keys** (automatic) | A normal Tumblr account and a free Tumblr app that you register yourself (takes about a minute) | Free. Tumblr's API has no paid tier | 250 new posts a day per Tumblr user, counted across all apps and the website. 250 image uploads, 20 videos and 60 minutes of video a day. Your app gets 1,000 API calls an hour and 5,000 a day. A post uses 1 call | None. A newly registered app can post, queue, draft and schedule straight away (as of October 2026) |
| **Hand-off** (you press Post) | Nothing | Free | The same daily limits, because you post yourself | None |

Tumblr's daily limits reset once per calendar day on Tumblr's server clock. Tumblr does not say which time zone that clock uses. When a limit is hit, NEFORUM shows "daily posting limit reached" and tries again later or offers the hand-off.

## How it works

### What the automatic tier does

- **Text** is split into one Tumblr paragraph per line. A paragraph holds at most 4,096 characters, so NEFORUM splits longer lines at a space. A whole post can hold up to 524,288 characters.
- **Title**: shown as a large heading at the top of the post. Tumblr posts have no separate title field.
- **Links** written in the text become clickable. A post's **link** becomes a link preview card at the end of the post, and is also set as the post's **source**.
- **Tags** go into Tumblr's tag field and are not added to the text. Tags cannot contain commas, so NEFORUM turns any comma into a space.
- **Images**: up to 30 per post. JPEG, PNG and WEBP files can be up to 20 MB and must be RGB (CMYK files are refused). GIFs can be up to 10 MB. Alt text is sent with each image.
- **Video**: one uploaded MP4 or MOV per post, up to 500 MB and 10 minutes. You can mix images and a video in one post.
- **Scheduling on Tumblr's side**: if you schedule a post, NEFORUM sends it to Tumblr straight away as a scheduled queue item (`state` `queue` with `publish_on`). Tumblr publishes it at the chosen time, so NEFORUM does not need to be running then. If you edit, reschedule, delete or "publish now" the post, NEFORUM first deletes the copy Tumblr is holding (`/post/delete`). NEFORUM keeps the schedule on your device instead when Tumblr cannot hold the post: drafts and private posts (Tumblr only schedules queued posts), and posts due in less than 5 minutes (plus the time a large upload needs).
- **Post state**: the per-post option `state` can be `published` (the default), `queue` (added to your blog's queue), `draft` or `private`. If you set the post's visibility to *private*, NEFORUM creates a private post.

### Staying signed in

A Tumblr sign-in lasts only 42 minutes. NEFORUM renews it automatically, and Tumblr hands out a new renewal key each time. If NEFORUM is not used for **42 days**, the renewal key expires and you need to click **Reconnect** once. The same happens if you remove the app's access on Tumblr. Accounts connected with OAuth 1.0a keys are never renewed and don't expire.

Your Secret Key is stored only in this device's secure storage, next to the sign-in. NEFORUM never sends it anywhere except to Tumblr.

### Why OAuth 1.0a keys

The browser sign-in uses OAuth 2. NEFORUM renews it every 42 minutes, and Tumblr hands out a new renewal key each time and cancels the old one. When the same blog is on two devices (copied with **Settings → Move to another device**, or synced), the first device to renew cancels the other one's sign-in, and that device has to reconnect.

Tumblr's API also accepts OAuth 1.0a: every route NEFORUM uses (listing your blogs, creating posts with photos and videos, queueing and deleting scheduled posts) requires "a signed request that meets the OAuth 1.0a Protocol" or OAuth 2. An OAuth 1.0a token and token secret are not renewed and don't change, so every device can use the same keys. Tumblr's API console shows them for your own app (as of October 2026).

Good to know:

- The token belongs to your Tumblr user and your app, not to one blog. The same four keys work for every NEFORUM account you add for your blogs.
- To switch an account you already connected in the browser, connect it again with the keys. NEFORUM replaces the stored sign-in; your posts keep pointing to the account.
- Every key request is signed with the current time. If a device's clock is off by more than a few minutes, Tumblr refuses the keys: set the clock right.
- Anyone who has the four keys can post to your blogs. Treat them like a password. They stop working when you remove the app's access on Tumblr.
- The token has to come from the console for the **same** app as the Consumer Key and Secret Key. Keys from two different apps are refused.

### Quote, chat and audio posts

| Post type | What you write | What Tumblr gets |
|---|---|---|
| **Quote** | The quote as the text; who said it in **Quote source** (or the title) | The words in Tumblr's large quote style, then "— source" |
| **Chat** | One line per speaker: `Alex: Did you see it?` | Each line as a chat line, the speaker in bold; the title on top |
| **Audio** | The track's link (SoundCloud, Spotify, Bandcamp...) in the Link field or the text, plus anything you want to say | Tumblr's player for the track, then your text |

With your own API keys NEFORUM posts them directly. Without keys (hand-off): quote and chat posts open Tumblr's share tool filled in; audio posts open `https://www.tumblr.com/new/audio`, with the track's link listed to paste. With the browser extension, Tumblr's full editor opens (`/new/quote`, `/new/chat`, `/new/audio`): the extension puts the track into the audio post's link field and the text below; a quote's source is listed in its panel with **Insert**.

An audio post needs a link to a service Tumblr can play; NEFORUM does not upload audio files.

### Hand-off

Which Tumblr page opens depends on your device and setup.

#### On a computer with the NEFORUM browser extension

With a browser paired ([Browser extension](../browser-extension.md)), NEFORUM opens Tumblr's **full post editor** for the kind of post, and the extension fills it in, files included:

| Your post | Tumblr opens |
|---|---|
| Text | `https://www.tumblr.com/new/text` |
| Photos (with or without text) | `https://www.tumblr.com/new/photo` |
| A video | `https://www.tumblr.com/new/video` |
| A link and text, no media | `https://www.tumblr.com/new/link`: the link goes into Tumblr's URL field (Tumblr turns it into a link card) and your text below it |

This replaces the share tool described below, which is a simplified page that takes text only (photos only as links on a media host), and nothing is put on your media host. Tags go in with **Insert** in the extension's panel.

#### Text and link posts

NEFORUM opens Tumblr's official share tool (`https://www.tumblr.com/widgets/share/tool`), filled in with your text, title and tags. A post with a link uses Tumblr's link layout: the link is the post, your text is its caption. If you are not signed in, Tumblr asks you to sign in first and then opens the filled-in post.

#### Photo posts on a computer, with a media host

If you have set up a **media host** in **Settings** (your own S3/R2 bucket, WebDAV, Litterbox, your own links, ...), NEFORUM fills in photo posts too:

1. NEFORUM uploads the photos to your media host. It asks for a lifetime of about **24 hours**, so hosts that can expire files delete them after a day. Post within that day.
2. The share tool opens as a **photo post** with your photos (several photos become a photoset), your text as the caption and your tags. Tumblr's share tool has no title for photo posts, so the title becomes the first line of the caption. The post's link (or the per-post `tumblrSourceUrl` option) is passed as the post's source.
3. Add the alt text yourself: the share tool cannot take it. NEFORUM lists it for each photo.

The share tool takes photos only as links, which is why a media host is needed. NEFORUM never uploads anything when no media host is set up. If the upload fails (host unreachable, file larger than the host accepts), NEFORUM falls back to the steps below and says why.

**Videos are not uploaded.** The share tool's video posts take a link or embed code from a video service, not a video file, so a video from your device cannot be filled in this way. A post with photos and a video gets the photos filled in; add the video in Tumblr's editor or post it separately.

#### Photo and video posts on a computer, without a media host

Tumblr's website cannot receive files from another program, so NEFORUM:

1. puts your text on the clipboard and lists the tags and alt texts;
2. opens Tumblr's new post page: `https://www.tumblr.com/new/photo` for photos, `https://www.tumblr.com/new/video` for a video;
3. lets you click **Save media to Downloads** in the hand-off window. NEFORUM saves the files with friendly names and opens the folder, so you can drag them into Tumblr's post.

Paste the text, add the tags and click **Post now**.

#### Phones (Android and iPhone)

NEFORUM opens the share sheet with your photos or video. Pick **Tumblr** (the Android app is `com.tumblr`; on iPhone the Tumblr share extension), paste the text if the app leaves it out and add the tags. This is the same with or without a media host. Tumblr documents no URL scheme for opening its iPhone app, so NEFORUM does not use one.

## Limits

- **No threads.** Tumblr has no reply chains. A long text simply becomes a long post.
- **No content warnings or community labels.** Tumblr's "mature" labels cannot be set through the API. Set them on tumblr.com after posting.
- **No unlisted or followers-only posts.** Such posts are published publicly. Use *private* to hide a post.
- **One video at a time.** Tumblr refuses a new video while the previous one is still processing. NEFORUM shows "still processing your previous video" and retries a few minutes later.
- **Scheduled posts and the queue**: a blog queue holds at most 1,000 posts and publishes at most 50 a day. A Tumblr Premium page mentions a different queue figure (2,000); Tumblr has not clarified which is correct. A scheduled post gets a new ID when it is published (Tumblr calls the old one the "genesis" ID, and it can no longer be used to look the post up), so for scheduled posts NEFORUM links to your blog rather than to the post. For the same reason, if NEFORUM tries to remove a scheduled post within 5 minutes of its publishing time and Tumblr no longer finds it, NEFORUM reports that it may already be live instead of assuming it is gone.
- **Tags**: Tumblr is commonly said to allow 30 tags per post, and NEFORUM warns above 30. Tumblr's own documentation no longer states this limit, so it is unconfirmed.
- **Daily limits are per Tumblr user**, not per app. Posts you make on tumblr.com or in the Tumblr app count too.
- **Tumblr's rules**: Tumblr's User Guidelines forbid automated or systematic posting aimed at spam. Use NEFORUM for your own, user-initiated posts and keep the volume modest.

## Troubleshooting

### If the sign-in fails after you click Allow

Tumblr shows its permission page even when the return address NEFORUM asks for is not registered in your app. After **Allow** it then sends the browser back with an error instead of a sign-in, and NEFORUM shows **Sign-in failed** with Tumblr's reason. The address NEFORUM asks for on a computer is `http://localhost:52771/callback`, so it must appear in **OAuth2 redirect URLs** exactly like that.

- **Your app lists a different address** (for example an older app registered with `http://127.0.0.1:52771/callback`): enter that address in **Redirect URI (advanced)** in NEFORUM, or change the app to `http://localhost:52771/callback`.
- Tumblr refuses to save some addresses with "The url's domain is not valid": `127.0.0.1` and home-network IPs such as `192.168.x.x`. `localhost` is accepted.

On a computer the address must keep port `52771` and the path `/callback`. NEFORUM listens there only while you sign in.

Before NEFORUM 1.0.4 the app asked Tumblr for `http://127.0.0.1:52771/callback` unless the advanced field was filled in, which is why sign-in failed for apps registered with `localhost`.

## Sources

- Tumblr API documentation (OAuth 2, rate limits, NPF post creation, error codes): <https://github.com/tumblr/docs/blob/master/api.md> (also <https://www.tumblr.com/docs/en/api/v2>)
- OAuth 1.0a (HMAC-SHA1 in the `Authorization` header; the "OAuth" authentication level of `/user/info`, `/posts` and `/post/delete`): the "Authentication" section of <https://github.com/tumblr/docs/blob/master/api.md>
- API console (Consumer Key and Consumer Secret, then **Authenticate**; **Show keys** lists Token and Token Secret): <https://api.tumblr.com/console>
- Neue Post Format specification (blocks, 4,096 code points per text block, 30 images and 1 uploaded video per post): <https://github.com/tumblr/docs/blob/master/npf-spec.md>
- Writing posts (524,288 characters per post): <https://help.tumblr.com/knowledge-base/writing-posts/>
- Images and GIFs (20 MB, GIF 10 MB, RGB only, 30 images on the web): <https://help.tumblr.com/knowledge-base/image-gif-troubleshooting/>
- Posting video (MP4/MOV, 500 MB, 10 minutes, 20 videos and 60 minutes a day): <https://help.tumblr.com/knowledge-base/posting-video/>
- Queue limits: <https://help.tumblr.com/knowledge-base/queue/>
- Share button / share tool parameters (`posttype` text, photo, link, quote, chat or video; `content` is one photo URL or a comma-separated list for a photoset; `caption` for photo, link, video and quote posts; `title` only for text, link and chat posts; comma-separated `tags`; `canonicalUrl`): <https://help.tumblr.com/hc/en-us/share-button-documentation/> (<https://www.tumblr.com/docs/en/share_button> redirects there)
- Video by link must come from a supported video service ("If you provide an unsupported service's URI you may receive a 400 response", legacy post creation in <https://github.com/tumblr/docs/blob/master/api.md>)
- iOS: URL schemes are listed as deprecated, the share extension is the supported route: <https://github.com/tumblr/TMTumblrSDK>
- Register an app: <https://www.tumblr.com/oauth/apps>
- API License Agreement: <https://www.tumblr.com/policy/en/api-license-agreement>
- User Guidelines: <https://www.tumblr.com/policy/en/user-guidelines>
- Redirect URL quirks: <https://github.com/tumblr/docs/issues/122> (custom scheme with trailing slash; `state` is required) and <https://github.com/tumblr/docs/issues/101> (domain validation)
- Token lifetimes (42 minutes / 42 days): <https://github.com/tumblr/docs/issues/134>
- Video media must be an object, not an array: <https://github.com/tumblr/docs/issues/88>

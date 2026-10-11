# Tumblr

NEFORUM can post to **any of your Tumblr blogs**, both your main blog and side blogs. You can connect it in two ways:

| Tier | What you need | Cost | Limits | Review |
|---|---|---|---|---|
| **Your own API keys** (automatic) | A normal Tumblr account and a free Tumblr app that you register yourself (takes about a minute) | Free. Tumblr's API has no paid tier | 250 new posts a day per Tumblr user, counted across all apps and the website. 250 image uploads, 20 videos and 60 minutes of video a day. Your app gets 1,000 API calls an hour and 5,000 a day. A post uses 1 call | None. A newly registered app can post, queue, draft and schedule straight away (as of October 2026) |
| **Hand-off** (you press Post) | Nothing | Free | The same daily limits, because you post yourself | None |

Tumblr's daily limits reset once per calendar day on Tumblr's server clock. Tumblr does not say which time zone that clock uses. When a limit is hit, NEFORUM shows "daily posting limit reached" and tries again later or offers the hand-off.

## What the automatic tier does

- **Text** is split into one Tumblr paragraph per line. A paragraph holds at most 4,096 characters, so NEFORUM splits longer lines at a space. A whole post can hold up to 524,288 characters.
- **Title**: shown as a large heading at the top of the post. Tumblr posts have no separate title field.
- **Links** written in the text become clickable. A post's **link** becomes a link preview card at the end of the post, and is also set as the post's **source**.
- **Tags** go into Tumblr's tag field and are not added to the text. Tags cannot contain commas, so NEFORUM turns any comma into a space.
- **Images**: up to 30 per post. JPEG, PNG and WEBP files can be up to 20 MB and must be RGB (CMYK files are refused). GIFs can be up to 10 MB. Alt text is sent with each image.
- **Video**: one uploaded MP4 or MOV per post, up to 500 MB and 10 minutes. You can mix images and a video in one post.
- **Scheduling on Tumblr's side**: if you schedule a post, NEFORUM sends it to Tumblr straight away as a scheduled queue item (`state` `queue` with `publish_on`). Tumblr publishes it at the chosen time, so NEFORUM does not need to be running then. If you edit, reschedule, delete or "publish now" the post, NEFORUM first deletes the copy Tumblr is holding (`/post/delete`). NEFORUM keeps the schedule on your device instead when Tumblr cannot hold the post: drafts and private posts (Tumblr only schedules queued posts), and posts due in less than 5 minutes (plus the time a large upload needs).
- **Post state**: the per-post option `state` can be `published` (the default), `queue` (added to your blog's queue), `draft` or `private`. If you set the post's visibility to *private*, NEFORUM creates a private post.

## Set up "Your own API keys"

1. Sign in to Tumblr in your browser and open <https://www.tumblr.com/oauth/apps>. Click **Register application**.
2. Fill in:
   - **Application Name**: anything, e.g. `NEFORUM for Ada`.
   - **Application Website**: any web address, for example `https://github.com/neforum-app/neforum`.
   - **Application Description**: e.g. `Posting from my own NEFORUM app`.
   - **Administrative contact email**: your e-mail address.
   - **Default callback URL**:

     ```
     http://127.0.0.1:52771/callback
     ```

   - **OAuth2 redirect URLs** (space separated). Enter both addresses on one line:

     ```
     http://127.0.0.1:52771/callback neforum://callback/
     ```

     The first one is for NEFORUM on Windows and macOS, the second for Android and iPhone. **Keep the slash at the end of `neforum://callback/`**: Tumblr only accepts app addresses like this one when they end in a slash. Each address must match exactly, character for character.
3. Click **Register**. Tumblr only switches on OAuth 2 for an app once it has at least one OAuth2 redirect URL.
4. On the app list, copy the **OAuth Consumer Key**. Click **Show secret key** and copy the **Secret Key** too.
5. In NEFORUM go to **Accounts > Add > Tumblr > Your own API keys** and paste both keys.
   - **Blog name** (optional): the blog to post to, i.e. the part before `.tumblr.com`. Leave it empty to use your main blog. To post to several blogs, add one NEFORUM account per blog. They can all use the same keys.
6. Click **Connect**. Your browser opens Tumblr's permission page. Click **Allow**. NEFORUM asks for `basic` (read your blog list), `write` (create posts) and `offline_access` (stay signed in).

### If Tumblr refuses the redirect address

Tumblr checks the web address when you save the app. Some addresses are refused with "The url's domain is not valid". Others are known to be refused too, such as home-network IPs like `192.168.x.x`. If `http://127.0.0.1:52771/callback` is refused:

1. Register `http://localhost:52771/callback` instead, as both the default callback and an OAuth2 redirect URL.
2. In NEFORUM, enter the same address in the **Redirect URI (advanced)** field.

On a computer the address must keep port `52771` and the path `/callback`.

### Staying signed in

A Tumblr sign-in lasts only 42 minutes. NEFORUM renews it automatically, and Tumblr hands out a new renewal key each time. If NEFORUM is not used for **42 days**, the renewal key expires and you need to click **Reconnect** once. The same happens if you remove the app's access on Tumblr.

Your Secret Key is stored only in this device's secure storage, next to the sign-in. NEFORUM never sends it anywhere except to Tumblr's sign-in server.

## Without API keys (hand-off)

No setup is needed. You check the post and click **Post now** yourself. Your text (title, text and link) is always on the clipboard too, and values that go into separate fields (tags, alt text) are listed in the hand-off window so you can copy them one by one.

### Text and link posts

NEFORUM opens Tumblr's official share tool (`https://www.tumblr.com/widgets/share/tool`), filled in with your text, title and tags. A post with a link uses Tumblr's link layout: the link is the post, your text is its caption. If you are not signed in, Tumblr asks you to sign in first and then opens the filled-in post.

### Photo posts on a computer, with a media host

If you have set up a **media host** in **Settings** (your own S3/R2 bucket, WebDAV, Litterbox, your own links, ...), NEFORUM fills in photo posts too:

1. NEFORUM uploads the photos to your media host. It asks for a lifetime of about **24 hours**, so hosts that can expire files delete them after a day. Post within that day.
2. The share tool opens as a **photo post** with your photos (several photos become a photoset), your text as the caption and your tags. Tumblr's share tool has no title for photo posts, so the title becomes the first line of the caption. The post's link (or the per-post `tumblrSourceUrl` option) is passed as the post's source.
3. Add the alt text yourself: the share tool cannot take it. NEFORUM lists it for each photo.

The share tool takes photos only as links, which is why a media host is needed. NEFORUM never uploads anything when no media host is set up. If the upload fails (host unreachable, file larger than the host accepts), NEFORUM falls back to the steps below and says why.

**Videos are not uploaded.** The share tool's video posts take a link or embed code from a video service, not a video file, so a video from your device cannot be filled in this way. A post with photos and a video gets the photos filled in; add the video in Tumblr's editor or post it separately.

### Photo and video posts on a computer, without a media host

Tumblr's website cannot receive files from another program, so NEFORUM:

1. puts your text on the clipboard and lists the tags and alt texts;
2. opens Tumblr's new post page: `https://www.tumblr.com/new/photo` for photos, `https://www.tumblr.com/new/video` for a video;
3. lets you click **Save media to Downloads** in the hand-off window. NEFORUM saves the files with friendly names and opens the folder, so you can drag them into Tumblr's post.

Paste the text, add the tags and click **Post now**.

### Phones (Android and iPhone)

NEFORUM opens the share sheet with your photos or video. Pick **Tumblr** (the Android app is `com.tumblr`; on iPhone the Tumblr share extension), paste the text if the app leaves it out and add the tags. This is the same with or without a media host. Tumblr documents no URL scheme for opening its iPhone app, so NEFORUM does not use one.

## Known limitations

- **No threads.** Tumblr has no reply chains. A long text simply becomes a long post.
- **No content warnings or community labels.** Tumblr's "mature" labels cannot be set through the API. Set them on tumblr.com after posting.
- **No unlisted or followers-only posts.** Such posts are published publicly. Use *private* to hide a post.
- **One video at a time.** Tumblr refuses a new video while the previous one is still processing. NEFORUM shows "still processing your previous video" and retries a few minutes later.
- **Scheduled posts and the queue**: a blog queue holds at most 1,000 posts and publishes at most 50 a day. A Tumblr Premium page mentions a different queue figure (2,000); Tumblr has not clarified which is correct. A scheduled post gets a new ID when it is published (Tumblr calls the old one the "genesis" ID, and it can no longer be used to look the post up), so for scheduled posts NEFORUM links to your blog rather than to the post. For the same reason, if NEFORUM tries to remove a scheduled post within 5 minutes of its publishing time and Tumblr no longer finds it, NEFORUM reports that it may already be live instead of assuming it is gone.
- **Tags**: Tumblr is commonly said to allow 30 tags per post, and NEFORUM warns above 30. Tumblr's own documentation no longer states this limit, so it is unconfirmed.
- **Daily limits are per Tumblr user**, not per app. Posts you make on tumblr.com or in the Tumblr app count too.
- **Tumblr's rules**: Tumblr's User Guidelines forbid automated or systematic posting aimed at spam. Use NEFORUM for your own, user-initiated posts and keep the volume modest.

## Sources

- Tumblr API documentation (OAuth 2, rate limits, NPF post creation, error codes): <https://github.com/tumblr/docs/blob/master/api.md> (also <https://www.tumblr.com/docs/en/api/v2>)
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

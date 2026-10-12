# TikTok

NEFORUM can reach TikTok in two ways. **Hand-off is the default and the one most people should use.**
The API tier works, but TikTok makes every post from a personal developer app **private**.

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Hand-off** (default) | Any TikTok account + the TikTok app (phone) or a browser (desktop) | Free | You tap **Post** in TikTok yourself. Public, private, whatever you choose there. |
| **Your own API keys** (Content Posting API) | A TikTok developer app (sandbox), connected from NEFORUM on Windows/macOS | Free | Fully automatic, but **PRIVATE ONLY** ("Only me") until TikTok audits your app. |

Status as of October 2026.

---

## Hand-off (recommended)

Nothing to set up. When you publish:

- **Phone:** NEFORUM copies your caption to the clipboard and opens the share sheet with your video/photos. Pick **TikTok**, long-press the caption box, paste, choose who can watch, tap **Post**.
- **Desktop:** NEFORUM copies the caption and opens TikTok Studio's upload page on the right tab: [photo](https://www.tiktok.com/tiktokstudio/upload?tab=photo) for photo posts, including the text card NEFORUM makes from a words-only post, and [video](https://www.tiktok.com/tiktokstudio/upload?tab=video) otherwise. Use **Save media to Downloads**, drag the files in, press Ctrl+V in the caption box, post.

Why the clipboard? TikTok ignores text handed to it with shared files, and it has no web link that opens a prefilled composer (nothing like X's "intent" links).

---

## Your own API keys (advanced; private posts only)

### Read this first

- **Every post is forced to private ("Only me").** TikTok: "All content posted by unaudited clients will be restricted to private viewing mode." Your app is unaudited unless TikTok approves it in a separate **Content Posting API audit**, which needs a demo video of a compliant app. TikTok's review guidelines say "Apps must not be for private or personal use", so a personal app is unlikely to pass.
- **Your TikTok account must be set to private** (TikTok app > Settings and privacy > Privacy > Private account). Otherwise TikTok refuses the upload with `unaudited_client_can_only_post_to_private_accounts`.
- **You must use a sandbox.** An app that has not passed App review cannot sign anyone in, not even you. A sandbox lets up to 10 "target users" (you) sign in and post, privately.
- **Connect from the desktop app.** TikTok only accepts `http://127.0.0.1:PORT/...` redirects for apps like NEFORUM. It does not accept `neforum://` redirects, so the connect button does not work on Android/iOS.
- Limits: around 15 API posts per account per day (TikTok says the number "varies"), 6 upload starts per minute, 5 pending inbox drafts per 24 hours, and a limited number of users posting through your app each day.

### Create your app

1. Sign in at <https://developers.tiktok.com/> with any TikTok account and open **Manage apps**. Create an app.
   Fill in the name, a 1024x1024 icon, category, description, and the Terms of Service and Privacy Policy URLs it asks for. You do not need to submit it for review.
2. Click **Add products** and add **Login Kit** and **Content Posting API**. In Content Posting API, turn on **Direct Post**.
3. Switch to **Sandbox** (top of the app page), create a sandbox, and under **Sandbox settings > Target users** add your own TikTok account. You log into that account and accept the developer terms. It can take up to an hour to appear.
4. In the sandbox's **Login Kit** settings choose the **Desktop** platform and add this redirect URI exactly:

   ```
   http://127.0.0.1:52771/callback
   ```

   (TikTok also allows a wildcard port, `http://127.0.0.1:*/callback`, but NEFORUM always uses port 52771.)
5. Make sure the scopes **user.info.basic**, **video.publish** and **video.upload** are enabled.
6. If the portal asks you to verify a URL or domain for the Content Posting API, do it (Manage URL properties). This is **required for photo posts**: TikTok downloads photos from an HTTPS URL, so set up a media host in NEFORUM and verify that host's domain or URL prefix.
7. Copy the sandbox **Client key** and **Client secret** into NEFORUM (Add account > TikTok > Your own API keys), click **Connect** and approve in the browser.

NEFORUM keeps the client secret and tokens in your device's secure storage. Access tokens last 24 hours and are refreshed automatically. The sign-in lasts 365 days, after which you reconnect.

### What NEFORUM sends

- **Video:** it asks TikTok for your creator settings, starts a Direct Post with your caption (max 2200 characters), uploads the file in pieces (one piece up to 64 MB, 16 MiB pieces above that), then waits until TikTok reports it posted. Privacy defaults to **SELF_ONLY**.
- **Photos (1-35, JPEG/WebP, 20 MB each, max 1080p):** only with a media host on a domain verified in your TikTok app. The post title (max 90) becomes the photo title and your text becomes the description (max 4000).
- **Comments, Duet and Stitch are off unless you allow them.** TikTok's sharing guidelines require this. TikTok also turns them off itself if your account disables them.

Per-post options (advanced, in the post's TikTok overrides):

| Key | Values |
|---|---|
| `privacyLevel` | `SELF_ONLY` (default), `PUBLIC_TO_EVERYONE`, `MUTUAL_FOLLOW_FRIENDS`, `FOLLOWER_OF_CREATOR`. Only works if TikTok offers it for your account and your app is audited. |
| `postMode` | `direct` (default) or `draft`: sends the video/photos to your TikTok inbox to finish in the app. **Video drafts carry no caption** (the API has no caption field for them). Whether drafts from an unaudited app can then be posted publicly in the app is not confirmed. |
| `allowComments`, `allowDuet`, `allowStitch` | `true` to allow |
| `coverTimestampMs` | frame (ms) for the video cover |
| `photoCoverIndex` | 0-based index of the cover photo |
| `autoAddMusic` | `true` to let TikTok add music to photo posts |
| `brandContent` / `brandOrganic` | paid partnership / your own business. Branded content cannot be private. |
| `isAigc` | `true` labels the post as AI-generated |

---

## Limits and known limitations

- No threads, no alt text, no content warnings, no link field. Links in captions are not clickable, so NEFORUM does not append the post link.
- Every TikTok post needs a video or photos. Text-only posts are impossible.
- Video: MP4/MOV/WebM, 360-4096 px per side, 23-60 fps, up to 10 minutes (and no longer than your account allows), 4 GB.
- No server-side scheduling via the API. NEFORUM must be running at the scheduled time.
- The in-app caption limit (reportedly 4000) is longer than the API's 2200. NEFORUM uses 2200 for both tiers.
- The whole video is read into memory before upload.
- Public post links are only known once TikTok's moderation makes the post public. For private posts NEFORUM stores TikTok's `publish_id` instead.

## Sources

- https://developers.tiktok.com/doc/content-posting-api-get-started
- https://developers.tiktok.com/doc/content-posting-api-reference-direct-post
- https://developers.tiktok.com/doc/content-posting-api-reference-photo-post
- https://developers.tiktok.com/doc/content-posting-api-reference-upload-video
- https://developers.tiktok.com/doc/content-posting-api-media-transfer-guide
- https://developers.tiktok.com/doc/content-posting-api-reference-query-creator-info
- https://developers.tiktok.com/doc/content-posting-api-reference-get-video-status
- https://developers.tiktok.com/doc/content-sharing-guidelines
- https://developers.tiktok.com/doc/login-kit-desktop
- https://developers.tiktok.com/doc/oauth-user-access-token-management
- https://developers.tiktok.com/doc/tiktok-api-v2-get-user-info
- https://developers.tiktok.com/doc/tiktok-api-v2-rate-limit
- https://developers.tiktok.com/docs/en/add-a-sandbox
- https://developers.tiktok.com/docs/en/getting-started-create-an-app
- https://developers.tiktok.com/docs/en/app-review-guidelines

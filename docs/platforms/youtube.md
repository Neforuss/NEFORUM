# YouTube

NEFORUM can reach YouTube in two ways. Every YouTube post is **one video** with a **title** (required) and a **description**. Images, text-only posts and Community posts are not possible: Google has no API for Community posts.

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Your own API keys** (default; YouTube Data API v3) | A Google account with a YouTube channel, plus a free Google Cloud project with a "Desktop app" OAuth client that you create. Connect from NEFORUM on Windows or macOS. | Free (no paid plan exists) | Fully automatic upload with title, description, tags, visibility and scheduling. **May be locked to private** (see below). |
| **Hand-off** | Any YouTube account, plus the YouTube app (phone) or a browser (desktop) | Free | You finish the upload in YouTube yourself. Public, unlisted, private, whatever you pick there. |

Status as of October 2026.

---

## Your own API keys

### Read this first

- **Uploads may be locked PRIVATE.** Your Google Cloud project has not been through YouTube's *API Services compliance audit*. YouTube Help (answer 7300965) says videos uploaded through an unverified API service are **locked as private**, cannot be appealed, and have to be uploaded again through the YouTube app or site. Since 2020 the API reference has said the same thing. **On 2026-10-08 Google changed the `videos.insert` reference to say that uploads from unverified projects "are not restricted to private viewing mode".** The Help Center page did not change, and the revision history has no entry for it. NEFORUM can't tell which page is right, so after every upload it checks the visibility YouTube reports. If YouTube made the video private, NEFORUM shows a warning. If you need guaranteed public videos, use **Hand-off**.
- The audit that removes the lock is for real products. It needs a public HTTPS website, a privacy policy, terms of service and a demo account, so a personal project usually can't pass it.
- **Quota:** each Google Cloud project gets **100 uploads (`videos.insert` calls) per day**, in a separate quota bucket (since 2026-06-01). All other calls share **10,000 units per day**; reading your channel costs 1 unit. Quotas reset at **midnight Pacific time**. Even failed requests count. YouTube can also stop a channel that uploads too much (`uploadLimitExceeded`).
- **Testing vs. production:** if your Google Auth Platform app stays in *Testing*, Google ends your sign-in **every 7 days** and you have to reconnect. Click **Publish app** (step 4 below) to avoid that. Google then shows an "unverified app" warning during sign-in. That warning is normal for your own app.
- **Connect from the desktop app.** Google only accepts `http://127.0.0.1` sign-ins for "Desktop app" clients. It rejects `neforum://` (custom schemes must contain a dot and belong to an iOS/Android client), so the Connect button doesn't work on Android/iOS.
- Channels that are not phone-verified can't upload videos longer than **15 minutes**. Verify at <https://www.youtube.com/verify>.

### Create your own Google app (about 10 minutes)

1. Open <https://console.cloud.google.com/projectcreate> and create a project (any name, e.g. "NEFORUM for me").
2. Enable the API: <https://console.cloud.google.com/apis/library/youtube.googleapis.com>, then click **Enable** on **YouTube Data API v3**.
3. Open **Google Auth Platform** (called "OAuth consent screen" in older guides) at <https://console.cloud.google.com/auth/overview> and click **Get started**. Enter an app name and your e-mail address, choose **External** as the audience, add your contact e-mail and finish.
4. Go to **Audience** and click **Publish app** so the status is **In production**. If you'd rather stay in *Testing*, add your own Google address under **Test users** and expect to reconnect weekly.
5. Go to **Data Access**, click **Add or remove scopes**, add these two and **Save**:
   - `https://www.googleapis.com/auth/youtube.upload` (upload videos)
   - `https://www.googleapis.com/auth/youtube.readonly` (lets NEFORUM show which channel is connected)
6. Go to **Clients**, click **Create client**, and pick Application type **Desktop app**. Give it any name and click **Create**.
   - A Desktop app client has no redirect-URI setting. NEFORUM signs in through **`http://127.0.0.1:52771/callback`**, which Google allows for Desktop clients automatically.
   - Do **not** choose "Web application", "Android" or "iOS". They don't accept this sign-in address.
7. Copy the **Client ID** (ends in `.apps.googleusercontent.com`) and the **Client secret**.
8. In NEFORUM: **Accounts > Add > YouTube > Your own API keys**. Paste both values and click **Connect**.
9. Your browser opens Google. Pick the Google account that owns your channel. When Google says *"Google hasn't verified this app"*, click **Advanced**, then **Go to (your app name) (unsafe)**. It is your own app. **Tick both YouTube checkboxes** and continue.

NEFORUM stores the tokens and the client secret only in this device's secure storage. To disconnect, remove the account in NEFORUM; it revokes the token at Google. Google's policies don't allow sharing one OAuth client across users, so every NEFORUM user creates their own.

### What NEFORUM sends

- **Title:** the post title. If it's empty, NEFORUM uses the first line of your text (max 100 characters).
- **Description:** your text (max 5,000 bytes; emoji and accented letters use 2-4 bytes each).
- **Tags:** your hashtags go into the tags field. All tags together can use 500 characters, counting the commas between them and two quote marks for every tag that contains a space.
- YouTube doesn't allow `<` or `>` in titles, descriptions or tags. NEFORUM replaces them with `‹ ›`.
- **Visibility:** comes from the post visibility (public, unlisted, or private for anything else). Per-post override: `privacyStatus` = `public` / `unlisted` / `private`.
- **Scheduling:** if you let YouTube hold the schedule, the video uploads as *private* with `publishAt` and YouTube makes it public at that time. This doesn't work if the video is locked private (see above).
- Other per-post options: `categoryId` (e.g. `22` = People & Blogs), `notifySubscribers` (default on), `madeForKids` (default off), `containsSyntheticMedia` (declare realistic AI-altered content).
- Vertical or square videos of 3 minutes or less automatically become **Shorts**. There is no separate Shorts switch.
- The link to the result is `https://youtu.be/<video id>`.

### Known limitations

- NEFORUM loads the whole video into memory before uploading, so very large files (several GB) may fail on devices with little RAM. Interrupted uploads resume where they stopped, up to 3 times. If the upload session expires, NEFORUM has to start over, which uses another upload from your daily quota.
- No custom thumbnails, playlists, captions or Community posts.
- If YouTube rejects the video after processing (copyright, duplicate, too long), you'll see it in YouTube Studio. NEFORUM only reports problems YouTube returns during the upload.

---

## Hand-off

Nothing to set up. When you publish:

- **Android / iOS:** NEFORUM copies the title, description and tags to your clipboard and opens the share sheet with your video. Pick **YouTube**. The YouTube app opens its upload editor with the video (the iOS YouTube app has a share extension since version 19.47.7). Paste the title and description, choose the visibility and tap **Upload**.
- **Desktop:** NEFORUM copies the text and opens <https://www.youtube.com/upload> (YouTube Studio's upload dialog). Drop the file in, paste the text, choose the visibility and publish.

Why the clipboard? YouTube takes only the video file from the share sheet, and its upload page has no link parameters for a title or description. You also set the schedule, tags and thumbnail in YouTube.

---

## Sources

- https://developers.google.com/youtube/v3/docs/videos/insert (checked 2026-10-10, page updated 2026-10-08)
- https://developers.google.com/youtube/v3/docs/videos (title, description and tag limits, publishAt)
- https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol
- https://developers.google.com/youtube/v3/determine_quota_cost (checked 2026-10-10, page updated 2026-10-08)
- https://developers.google.com/youtube/v3/revision_history (2025-12-04 and 2026-06-01 quota changes)
- https://developers.google.com/youtube/v3/guides/quota_and_compliance_audits
- https://developers.google.com/youtube/v3/guides/auth/installed-apps
- https://developers.google.com/identity/protocols/oauth2/native-app
- https://developers.google.com/youtube/terms/developer-policies
- https://support.google.com/youtube/answer/7300965 (private lock, no appeal; checked 2026-10-10)
- https://support.google.com/youtube/contact/yt_api_form (compliance audit form)
- https://support.google.com/cloud/answer/15549945 (Google Auth Platform, testing vs. production)

# Instagram

NEFORUM can reach Instagram in two ways. Pick one when you add the account. You can add the same Instagram account twice, once per way.

| | Hand-off (default) | Your own API keys |
|---|---|---|
| Account type | Any account, **personal included** | **Professional only** (Business or Creator) |
| What you do | Paste the caption and tap **Share** in Instagram | Nothing. NEFORUM posts for you |
| Cost | Free | Free (Meta does not charge for the API) |
| Quota | None from NEFORUM | 100 API posts per account per rolling 24 hours (a carousel counts as one) |
| App review | Not needed | Not needed, as long as you only post to **your own** accounts |
| Extra setup | None | A Meta developer app **and** a media host |

Status as of October 2026: Meta's "Instagram API with Instagram Login" (graph.instagram.com, Graph API v25.0) is the current API. The old Basic Display API, which worked with personal accounts but could never publish, was shut down on 4 December 2024. **Personal accounts cannot post through any official API.** For them, use Hand-off or switch the account to professional. Switching is free and takes a minute in the Instagram app.

---

## Hand-off (any account)

There is nothing to set up. When you post:

1. NEFORUM copies your caption to the clipboard.
2. On a phone, the share sheet opens with your photo(s) or video. Choose **Instagram**, then Feed, Reel or Story. On a computer, NEFORUM opens https://www.instagram.com/. Click **Create** there and pick the files.
3. Long-press the caption box and tap **Paste**.
4. Tap **Share**.

Limitations:

- Instagram ignores any caption that arrives through the share sheet, on both Android and iOS. That is why the caption goes on the clipboard instead. On iOS, Instagram may ask "Allow Paste?" the first time.
- Instagram has no web link that opens a pre-filled post, so there is no "web intent" for Instagram.
- Some phones share only the first file when you hand over several at once. If only one arrives, add the rest from your gallery inside Instagram.
- Long posts cannot be split into a thread. Instagram has no threads.

---

## Your own API keys (professional accounts)

### What you need

1. **A professional Instagram account.** In the Instagram app, go to *Settings > Account type and tools > Switch to professional account*. Business and Creator both work. You do **not** need a Facebook Page.
2. **A free Meta developer account and your own Meta app.** NEFORUM is open source, so it cannot ship a secret app key. Everyone uses their own app. As long as the app only posts to accounts that have a role on it (your own), Meta's default *Standard Access* is enough. You need no App Review and no Business Verification.
3. **A media host.** You set this up in NEFORUM under *Settings > Media hosting*, for example an S3/R2/B2 bucket, a WebDAV/Nextcloud share or your own server. Instagram does not accept file uploads for photos. It downloads every photo and video from a public `https://` link. NEFORUM uploads each file to your host just before posting and deletes it right after.

### Create your Meta app (about 10 minutes)

1. Open https://developers.facebook.com/apps and sign in. Accept the developer terms if this is your first app.
2. Click **Create app**. Choose the use case **Manage messaging & content on Instagram**. (If your dashboard does not offer it, choose **Other**, then the app type **Business**, and add the product **Instagram** with **Set up**.) Give it any name, for example "My NEFORUM". If the dashboard asks for a business portfolio, you may create or pick one.
3. Open **API setup with Instagram login** (some dashboards say *API setup with Instagram business login*) and click **Add all required permissions**. Make sure `instagram_business_content_publish` is in the list.
4. In section **3. Set up Instagram business login**, open **Business login settings**. Under **OAuth redirect URIs**, enter

   ```
   https://localhost:52771/callback
   ```

   Type it exactly as shown. **Click the suggestion in the dropdown** so it turns into a grey chip, then **Save**. Otherwise Meta shows "Please enter an OAuth redirect URI". Meta accepts only `https://` addresses here. Plain `http://127.0.0.1` and app links like `neforum://callback` are rejected. The dashboard sometimes adds a trailing slash. If it does, enter the URI with the slash in NEFORUM's *Redirect URI* field too.
5. In section **2. Generate access tokens**, click **Add account** and sign in with your Instagram account. If Instagram shows a tester invite, accept it in the Instagram app under *Settings > Apps and websites > Tester invites*.
6. At the top of the same page, copy the **Instagram app ID** and the **Instagram app secret** (click *Show*). These are **not** the Meta App ID and App Secret shown at the very top of the dashboard.

### Connect in NEFORUM

1. Go to *Add account > Instagram > Your own API keys*.
2. Paste the **Instagram app ID** and **Instagram app secret**. Leave *Redirect URI* as `https://localhost:52771/callback`, unless you registered something else in step 4.
3. Click **Connect**. Your browser opens Instagram. Log in and allow the two permissions NEFORUM asks for: `instagram_business_basic` (your profile) and `instagram_business_content_publish` (posting).
4. Instagram then sends your browser to `https://localhost:52771/callback?code=…`. That page **will not load**, which is expected. Copy the **whole address** from the address bar and paste it into NEFORUM. This works on phones too.

NEFORUM exchanges the code for a 60-day token and refreshes it automatically about once a week, whenever it publishes. Your app secret is only used while connecting and is not stored. If NEFORUM does not post for more than 60 days, the token expires and you must connect again.

**Shortcut without the browser step:** in step 5 above, click **Generate token** next to your account. Log in and paste the token into NEFORUM's *Or: access token* field. You can leave the app ID and secret empty. NEFORUM refreshes this token too: Instagram does not say how old a pasted token is, so NEFORUM refreshes it the first time it publishes after the token is a day old, and from then on knows when it expires.

### What gets posted

| Your post | Instagram post |
|---|---|
| 1 photo | Feed photo, with alt text if you wrote one |
| 1 video | Reel (all API feed videos are Reels now) |
| 2–10 photos/videos | Carousel. Every item is cropped to the first item's shape |
| "Story" switched on | Story with one photo or video. Stories have no caption via the API |

### Limits NEFORUM checks before posting

- Caption: 2,200 characters, at most 30 hashtags and 20 @mentions. Links in captions are not clickable.
- Photos: **JPEG only** through the API (PNG/GIF/WebP are refused), up to 8 MB, aspect ratio between 4:5 (portrait) and 1.91:1 (landscape). Photos narrower than 320 px are scaled up.
- Alt text: up to 1,000 characters, photos only. Reels and stories take none.
- Reels: MP4 or MOV, 3 seconds to 15 minutes, up to 300 MB, 9:16 recommended.
- Story videos: 3 to 60 seconds, up to 100 MB.
- 100 API-published posts per 24 hours per account. One part of Meta's docs still says 50, so the live number may be lower. NEFORUM reports Meta's "maximum number of posts" error as a quota problem and you can fall back to Hand-off.

### Known limitations

- **No scheduling on Instagram's side.** NEFORUM keeps scheduled posts itself and publishes at the chosen time. Instagram containers expire after 24 hours, so nothing is sent early.
- **Video processing takes time.** NEFORUM checks the status for about five minutes, as Meta recommends. Long Reels can take longer. If they do, the post fails with a "still processing" message and you can retry.
- **Rate limits depend on reach.** Meta allows roughly 4,800 calls × the account's impressions per 24 hours. A brand-new account with almost no views can be throttled after a few posts (errors 4, 17 or 80002, reported as a quota problem). A 10-item carousel needs about 25 calls.
- **"We restrict certain activity to protect our community"** (error 2207051) is Instagram's spam filter. NEFORUM stops and tells you. Wait before posting again.
- **"The media could not be fetched"** (error 2207052) means Instagram could not download from your media host. Check that the link is public, is not behind bot protection or a redirect, has not expired, and returns the file itself rather than a web page.
- Not supported yet: tagging people or products, locations, collaborators, music, cover images for Reels, trial Reels, and the binary video upload (`rupload.facebook.com`) that would avoid hosting videos.
- If you ever let *other* people's accounts use your Meta app, Meta requires App Review and Business Verification. NEFORUM's model is that everyone uses their own app.
- Hand-off for stories with stickers, or Android/iOS "Add to Story" deep links, need a Facebook App ID and are not used. The normal share sheet still offers Story.

---

## Sources

- Instagram Platform overview: https://developers.facebook.com/docs/instagram-platform/overview
- Instagram API with Instagram Login: https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login
- Business Login for Instagram (authorize, token exchange, long-lived tokens, refresh): https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/business-login
- Get started (GET /me fields, Generate token): https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/get-started
- Content publishing guide (containers, status polling, carousel, Reels, stories, 100 posts/24 h): https://developers.facebook.com/docs/instagram-platform/content-publishing
- IG User Media reference (parameters, image and video specifications): https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/media
- Content publishing limit: https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/content_publishing_limit
- Error codes: https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/error-codes
- Graph API rate limiting: https://developers.facebook.com/docs/graph-api/overview/rate-limiting
- Sharing to Feed (share intents): https://developers.facebook.com/documentation/instagram-platform/sharing-to-feed.md
- Sharing to Stories: https://developers.facebook.com/docs/instagram-platform/sharing-to-stories

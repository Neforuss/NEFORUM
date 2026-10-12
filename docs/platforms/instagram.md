# Instagram

*Last checked against Meta's developer documentation (the new `developers.facebook.com/documentation`
pages and their `llms.txt` index) on 11 October 2026, and against Meta's App Dashboard during a real setup
on the same day. NEFORUM uses the "Instagram API with Instagram Login" on `graph.instagram.com`, Graph API v25.0.*

NEFORUM can reach Instagram in two ways. Pick one when you add the account. You can add the same Instagram account twice, once per way.

| | Hand-off (default) | Your own API keys |
|---|---|---|
| Account type | Any account, **personal included** | **Professional only** (Business or Creator) |
| What you do | Paste the caption and tap **Share** in Instagram | Nothing. NEFORUM posts for you |
| Cost | Free | Free (Meta does not charge for the API) |
| Quota | None from NEFORUM | 100 API posts per account per rolling 24 hours according to the publishing guide; other pages say 50 (see "Where Meta's documentation disagrees") |
| App review | Not needed | Not needed, as long as you only post to **your own** accounts |
| Extra setup | None | A Meta developer app, the Instagram Tester role **and** a media host |

**Personal accounts cannot post through any official API.** The old Basic Display API, which worked with personal accounts but could never publish, was shut down on 4 December 2024. For personal accounts use Hand-off, or switch the account to professional: it is free and takes a minute in the Instagram app.

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

1. **A professional Instagram account.** In the Instagram app, go to *Settings > Account type and tools > Switch to professional account*. Business and Creator both work. You do **not** need a Facebook Page: "This API setup does not require a Facebook Page to be linked to the Instagram professional account."
2. **A free Meta developer account and your own Meta app.** NEFORUM is open source, so it cannot ship a secret app key; everyone uses their own app. Standard Access, which every new app gets, covers accounts you own or manage and have added to your app in the App Dashboard (Business Login page). App Review is "Not required" when "My app is only for a business I own or manage" (App Review page).
3. **A media host, even if you only post text.** Instagram does not take photo uploads: "the media must be hosted on a publicly accessible server at the time of the attempt." Every Instagram post needs a photo or video, so NEFORUM turns a text-only post into a text card (an image of your words), and that image goes through the host too. Without a host the composer says "Instagram needs a public media host (Settings → Media hosting)". NEFORUM uploads each file to your host just before posting and deletes it right after, where the host allows it.
   - **To start:** pick **Litterbox** under *Settings > Media hosting*. It needs no account and no setup. It is a free service run by a volunteer, with no guarantee: uploads can fail when its server has problems.
   - **For regular posting:** use a storage bucket you own (Backblaze B2, Cloudflare R2, Amazon S3) or a Nextcloud/WebDAV share. A bucket is the most reliable choice.
   - The [media hosting guide](../media-hosts.md) explains each host step by step (in NEFORUM also under *Settings > Media hosting > Guide*).

### Step 1: create your Meta app (about 5 minutes)

1. Open <https://developers.facebook.com/apps/creation/> and log in. Accept the developer terms if this is your first app.
2. Give the app any name, for example "My NEFORUM". Choose the use case **Manage messaging & content on Instagram** (Meta's docs write *Manage messaging and content on Instagram*; the dashboard's use case switcher later calls it **Instagram API**). If the dashboard instead asks for an app type, pick **Business**: the get-started guide warns that the Instagram Login setup needs a Business app. Want Threads too? Also tick **Access the Threads API**. One app can serve both (see the Threads guide).
3. If the wizard asks *Which business portfolio do you want to connect to this app?*, you can pick **I don't want to connect a business portfolio yet**. That is fine for posting to your own accounts. Finish the wizard.
4. Meta creates a second, Instagram-only app for you, named after yours with `-IG` at the end (for example "My NEFORUM-IG"). It has its own **Instagram app ID**, which is different from the Meta App ID. You only need it for browser sign-in (step 3b).
5. In the left menu open **Use cases** and click **Customize** on the Instagram use case. On **Permissions and features**, click **+ Add** next to **`instagram_business_basic`** and next to **`instagram_business_content_publish`**. In October 2026 neither was added by default.
   - The list cuts the names off ("instagram_busines…"). The rows are in alphabetical order: `…_basic`, `…_content_publish`, `…_manage_comments`, `…_manage_insights`, `…_manage_messages`. Each row's description starts with the full name, for example "The instagram_business_content_publish permission…".
   - The card **1. Add required messaging permissions** on *API setup with Instagram login* has a button **Add all required permissions**. It adds `instagram_business_basic` and two messaging permissions, but **not** `instagram_business_content_publish`, so add that one yourself. NEFORUM does not use the messaging permissions; they do no harm.

The left menu may also list *Facebook Login for Business* even though you did not choose it. You can ignore it.

### Step 2: make your Instagram account an Instagram Tester (required)

**Generate token** only works for accounts that have the **Instagram Tester** role. The *Generate access tokens* section says so too: it asks you to assign the role in the Roles tab before you go on.

1. In the left menu open **App roles > Roles**. Click **Add People**, choose **Instagram Tester** and enter your Instagram username.
2. Accept the invite in Instagram: **Settings > Apps and websites > Tester invites**.
3. Open **API setup with Instagram login** (left menu, under the Instagram use case; older dashboards: *Instagram > API setup with Instagram business login*). Don't confuse it with *API setup with Facebook login*. The **Instagram app ID** and **Instagram app secret** are shown at the top.
4. In **2. Generate access tokens**, your account now appears by itself, with its Instagram user ID and a **Generate token** link. In October 2026 no **Add account** click was needed. If your account is not listed, check that you accepted the invite and reload the page. Some dashboards show **Add account** instead: click it, log in to Instagram in the pop-up and follow the prompts.

Repeat steps 1 and 2 for every other Instagram account you want to post to.

### Step 3a: quickest, paste a token (recommended)

1. Still in **Generate access tokens**, click **Generate token** next to your account. An Instagram login pop-up opens. Log in, confirm and copy the token.
2. In NEFORUM go to *Add account > Instagram > Your own API keys* and paste it into **Access token from "Generate token"**. Leave the app ID, secret and redirect fields empty.
3. Press the connect button. NEFORUM checks the token with `GET /me?fields=user_id,username,...` and refuses personal accounts with a hint. A professional account connects straight away.
4. If you have not set up a media host yet, do it now (see "What you need"). Without one NEFORUM cannot post to Instagram, not even text.

"Access tokens from the App Dashboard are long-lived and are valid for 60 days" (get-started guide). Instagram does not tell NEFORUM how old a pasted token is, so NEFORUM renews it with `GET /refresh_access_token?grant_type=ig_refresh_token` the first time it publishes after the token is a day old (Meta only refreshes tokens that are at least 24 hours old and not expired). From then on it knows the expiry date and renews about once a week. No app secret is needed for any of this.

### Step 3b: alternative, browser sign-in

Use this if you prefer not to copy a token.

1. On **API setup with Instagram login**, in **Set up Instagram business login**, click **Set up**, then **Business login settings**. Under **OAuth redirect URIs** enter

   ```
   https://localhost:52771/callback
   ```

   Type it exactly. **Click the suggestion in the dropdown** so it turns into a grey chip, then **Save**. The dashboard sometimes adds a trailing slash; if it does, enter the URI with the slash in NEFORUM's *Redirect URI* field too. Meta's examples only use `https://` addresses; plain `http://127.0.0.1` and `neforum://callback` are rejected by the dashboard.
2. Fill in the **Deauthorization callback URL** and **Data deletion request URL** on the same screen if the dashboard insists (the same address is fine).
3. In NEFORUM paste the **Instagram app ID** and **Instagram app secret** (top of *API setup with Instagram login*: the ID of the `-IG` app from step 1.4, **not** the Meta App ID under *App settings > Basic*).
4. Press **Sign in with Instagram**. Log in and allow `instagram_business_basic` and `instagram_business_content_publish`.
5. Instagram sends your browser to `https://localhost:52771/callback?code=...#_`. That page **will not load**, which is expected. Copy the **whole address** from the address bar and paste it into NEFORUM. This works on phones too.

NEFORUM exchanges the code (valid for 1 hour, usable once) for a short-lived token (`POST https://api.instagram.com/oauth/access_token`), swaps that for a 60-day token (`GET /access_token?grant_type=ig_exchange_token`, needs the app secret) and renews it automatically about once a week. Your app secret is used only while connecting and is not stored. "Tokens that have not been refreshed in 60 days will expire and can no longer be refreshed": if NEFORUM does not post for 60 days, connect again.

### What gets posted

| Your post | Instagram post |
|---|---|
| 1 photo | Feed photo, with alt text if you wrote one |
| 1 video | Reel (`media_type=REELS`) |
| 2–10 photos/videos | Carousel. Instagram crops every image to the first image's aspect ratio |
| "Story" switched on | Story with one photo or video. Stories have no caption and no alt text via the API |

### Limits NEFORUM checks before posting

All numbers are from the IG User Media reference, the content publishing guide and the error-code reference:

- Caption: 2,200 characters, at most 30 hashtags and 20 @mentions. Links in captions are not clickable.
- Photos: "JPEG is the only image format supported" (PNG/GIF/WebP are refused; MPO and JPS too), up to 8 MB, aspect ratio between 4:5 and 1.91:1, 320 to 1440 px wide (others are scaled).
- Alt text: up to 1,000 characters, single photos and carousel photos only ("Reels and stories are not supported").
- Reels: MOV or MP4, 3 seconds to 15 minutes, up to 300 MB, 23–60 fps, at most 1920 px wide, 9:16 recommended.
- Story videos: 3 to 60 seconds, up to 100 MB.
- Carousels: 2 to 10 items, photos and videos mixed; "Carousels count as a single post".
- Publishing quota: see the next section.

### Where Meta's documentation disagrees

- **Posts per 24 hours.** The content publishing guide's overview says "Instagram accounts are limited to 100 API-published posts within a 24-hour moving period". The carousel section of the same guide says "50 published posts within a 24-hour period", and the `content_publishing_limit` reference gives `quota_total` as "currently `50`". NEFORUM's own counter allows 100; if Instagram's real limit is lower, Instagram answers with error 9 / 2207042, which NEFORUM reports as a quota problem (fall back to Hand-off, or wait a day).
- **App type.** The App Dashboard page calls the use case *Manage messaging and content on Instagram* (the dashboard itself showed *Manage messaging & content on Instagram* in October 2026); the get-started guide says to "select Business during the creation process". Both work for NEFORUM.
- **Where the token button lives.** The get-started guide says *Instagram > API setup with Instagram business login > Generate token*; the App Dashboard guide calls the page *API setup with Instagram Login* and the section *Generate access tokens*. Same screen, different dashboard generations.
- **Adding your account.** Meta's guides describe adding the account with **Add account** under *Generate access tokens*. In October 2026 the dashboard instead asked for the Instagram Tester role first (step 2), and the account then appeared by itself.
- **Error 36001 / 2207005** ("unsupported image format"): the reference lists a fix about permissions and token expiry, which looks like a copy error. NEFORUM treats it as a format problem (convert to JPEG).

### Troubleshooting

| What you see | What it means and what to do |
|---|---|
| "This is a personal Instagram account" | Switch to a professional account in Instagram, or use Hand-off. |
| Your account is not listed under *Generate access tokens*, or **Generate token** fails | The account does not have the Instagram Tester role yet, or the invite is not accepted. Do step 2. |
| Instagram refuses the pasted token (error 190) | The token expired or was cut off. Click **Generate token** again and paste all of it. |
| "Instagram did not grant permission to publish" | `instagram_business_content_publish` was not added (step 1.5) or was switched off during sign-in. Add it, then generate a new token or sign in again. |
| "Instagram needs a public media host (Settings → Media hosting)" | No media host is set. Pick one under *Settings > Media hosting*. Text-only posts need one too, because they are posted as a text card image. |
| "... couldn't store the file" or "... refused to store the file" | NEFORUM could not put the file on your media host, even after trying twice. "Couldn't store" (HTTP 500 and similar) is a problem on the host's side, often Litterbox's: try again later, or switch to a bucket you own (see the [media hosting guide](../media-hosts.md)). "Refused" means the host turned this file or your settings down; the message says why. |
| "Error validating verification code ... redirect_uri is identical" | The redirect URI in NEFORUM does not match the one under *Business login settings* character for character (watch the trailing slash), or the code was older than 1 hour / used twice. |
| Error 9 / 2207042 | Daily publishing limit reached; try again the next day. |
| Error 4 / 2207051 | Instagram's spam filter flagged the action (activity restricted to protect the community). Wait before posting again. |
| Error 25 / 2207050 | The account is inactive, checkpointed or restricted. Open the Instagram app and complete what it asks. |
| Error 9004 / 2207052 | Instagram could not download from your media host. Check that the link is public, not behind bot protection or a redirect, not expired, and returns the file itself. |
| Error 36003 / 2207009 | Aspect ratio outside 4:5 to 1.91:1. Crop the photo. |
| Error 36000 / 2207004 | Image larger than 8 MB. |
| Error 352 / 2207026 | Unsupported video: use MP4 or MOV. |
| Errors 4, 17, 80002 | Rate limit ("Calls within 24 hours = 4800 * Number of Impressions"). A brand-new account with almost no views can be throttled after a few posts. NEFORUM waits and retries later. |
| Error 24 / 2207008 right after creating the post | Normal for a few seconds; NEFORUM retries as the error-code reference recommends (1–2 retries over 30 seconds to 2 minutes). |
| Other people do not see your posts | Meta's general App modes rule is that data created by an app in Development mode "can only be seen by role users". If that happens, **Publish** the app (left menu). As of October 2026 the only required item was a **Privacy policy URL**; an app icon and a data deletion URL were optional. You can enter NEFORUM's, `https://neforus.com/neforum/privacy/`, or your own: see [A privacy policy URL for your Meta app](../meta-privacy-policy.md). |
| Everything stopped after months of silence | Meta marks an app **Inactive** after 90 days with no logins, API calls or webhooks and invalidates its tokens. Reconnect. |

### Known limitations

- **No scheduling on Instagram's side.** NEFORUM keeps scheduled posts itself and publishes at the chosen time. Instagram containers expire after 24 hours, so nothing is sent early.
- **Video processing takes time.** NEFORUM checks the status for about five minutes ("once per minute, for no more than 5 minutes"). Long Reels can take longer. If they do, the post fails with a "still processing" message and you can retry.
- Not supported yet: tagging people or products, locations, collaborators, music, cover images for Reels, trial Reels, and resumable video uploads (`rupload.facebook.com`, which Meta only offers to apps using Facebook Login for Business).
- If you ever let *other* people's accounts use your Meta app, Meta requires App Review and Business Verification (Advanced Access). NEFORUM's model is that everyone uses their own app.
- Hand-off for stories with stickers, or Android/iOS "Add to Story" deep links, need a Facebook App ID and are not used. The normal share sheet still offers Story.

---

## Official documentation

New LLM-oriented pages (index: <https://developers.facebook.com/documentation/instagram-platform/llms.txt>):

- Overview (access levels, tokens, rate limits): <https://developers.facebook.com/documentation/instagram-platform/overview>
- Instagram API with Instagram Login: <https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-instagram-login>
- Get started (Generate token, `/me`): <https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-instagram-login/get-started>
- Business Login for Instagram (authorize, code exchange, long-lived token, refresh): <https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-instagram-login/business-login>
- Create an app: <https://developers.facebook.com/documentation/instagram-platform/create-an-instagram-app>
- Instagram use case in the App Dashboard: <https://developers.facebook.com/documentation/development/create-an-app/instagram-use-case>
- Publish content: <https://developers.facebook.com/documentation/instagram-platform/content-publishing>
- Content publishing limit: <https://developers.facebook.com/documentation/instagram-platform/instagram-graph-api/reference/ig-user/content_publishing_limit>
- IG User Media (image and video specifications): <https://developers.facebook.com/documentation/instagram-platform/instagram-graph-api/reference/ig-user/media>
- Access token (`ig_exchange_token`): <https://developers.facebook.com/documentation/instagram-platform/reference/access_token>
- Refresh access token: <https://developers.facebook.com/documentation/instagram-platform/reference/refresh_access_token>
- Error codes: <https://developers.facebook.com/documentation/instagram-platform/instagram-graph-api/reference/error-codes>
- App Review: <https://developers.facebook.com/documentation/instagram-platform/app-review>
- App states (inactive apps): <https://developers.facebook.com/documentation/development/create-an-app/app-dashboard/app-states>
- Sharing to Feed / Stories (hand-off): <https://developers.facebook.com/documentation/instagram-platform/sharing-to-feed>, <https://developers.facebook.com/documentation/instagram-platform/sharing-to-stories>

Older pages: Graph API rate limiting <https://developers.facebook.com/docs/graph-api/overview/rate-limiting>, permissions reference <https://developers.facebook.com/docs/permissions>.

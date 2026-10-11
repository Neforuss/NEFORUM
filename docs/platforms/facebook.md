# Facebook in NEFORUM

*Last checked against Meta's developer documentation (the new `developers.facebook.com/documentation` pages
and their `llms.txt` index) on 11 October 2026. NEFORUM calls Graph API v25.0, the version the Pages API
guides use in their examples.*

## What works, in one paragraph

NEFORUM can post automatically **only to Facebook Pages you manage**. Meta took away API posting to
**personal profiles** in 2018 (`publish_actions` was removed) and removed the **Groups API** in April 2024.
No app, NEFORUM included, can post to your own timeline or to a group for you. For those, NEFORUM has a
**hand-off** mode: it copies your text, opens Facebook, and you tap **Post** yourself.

## Tiers

| Tier | Works for | What you need | Cost | Limits |
|---|---|---|---|---|
| **Hand-off** (default) | Personal profiles and Pages | Nothing. The Facebook app, or a browser where you are logged in | Free | You paste the text and tap Post yourself. Facebook never lets another app fill in your text. |
| **Your own API keys** | Pages only | A Facebook account that can create content on the Page, plus a free Meta developer app that you create and are admin of | Free (no paid Graph API tier) | 4,800 calls x the number of people who engaged with the Page per rolling 24 h. No App Review as long as only you (a person with a role on the app) use it. |

## Why no App Review is needed

* New Business-type apps are "automatically approved for Standard Access for all permissions and features"
  (Access levels). Standard Access permissions "can only be requested from app users who have a role on the
  requesting app". You created the app, so you are its administrator and have that role.
* "Apps in Development Mode can request any Permission from any app User who has a Role on the app"
  (Pages API overview).
* App Review and Business Verification are only needed for *Advanced Access*, which lets people **without**
  a role on your app use it. NEFORUM never needs that, because everyone uses their own app.

## Set up "Your own API keys" (about 10 minutes, once)

### 1. Create the app

1. Open <https://developers.facebook.com/apps/creation/> (log in with the Facebook account that manages the
   Page; register as a developer if asked, it is free).
2. Pick the use case **Manage everything on your Page** and finish the wizard. If Meta asks for a business
   portfolio you may skip it, or pick the one that owns your Page.

### 2. Add the permissions

1. In the left menu open **Use cases**, then **Customize** next to *Manage everything on your Page*.
2. `business_management`, `pages_show_list` and `public_profile` are added by default and cannot be removed.
3. Click **Add** next to **`pages_manage_posts`** and **`pages_read_engagement`**.
   (`pages_manage_posts` needs `pages_read_engagement` and `pages_show_list`; permissions reference.)

### 3. Copy the App ID and App Secret

Open **App settings > Basic**. Copy the **App ID** (the long number, also shown at the top of the dashboard)
and the **App Secret** (click **Show**; Facebook may ask for your password). Paste both into NEFORUM
(*Add account > Facebook > Your own API keys*).

### 4a. Quickest: paste a token from the Graph API Explorer (no redirect setup)

1. Open <https://developers.facebook.com/tools/explorer/>.
2. In the **Meta App** dropdown (top right) choose **your** app, not "Graph API Explorer".
3. In the **User or Page** dropdown choose **User Token**.
4. Under **Permissions** add `pages_show_list`, `pages_read_engagement`, `pages_manage_posts` and
   `business_management`.
5. Click **Generate Access Token** (some screens say *Get Access Token*). Facebook asks you to log in and
   approve: **select the Page(s)** NEFORUM may use (or "all current and future Pages").
6. Copy the token from the **Access Token** box and paste it into NEFORUM's
   **User access token from the Graph API Explorer** field. Optionally type your Page's name or ID.
7. Press the connect button. NEFORUM:
   * exchanges the token for a long-lived user token (`GET /oauth/access_token?grant_type=fb_exchange_token`,
     needs the App ID and App Secret; "A long-lived token generally lasts about 60 days");
   * reads your name (`GET /me`) and the permissions you granted (`GET /me/permissions`), and stops with a
     clear message if `pages_manage_posts`, `pages_read_engagement` or `pages_show_list` is missing;
   * lists your Pages (`GET /me/accounts`) and stores the Page token of the chosen Page. Page tokens obtained
     with a long-lived user token "do not have an expiration date".

Do **not** pick your Page in the *User or Page* dropdown: that gives a Page token, which NEFORUM cannot turn
into a long-lived one. NEFORUM recognises it and asks for the User Token instead.

### 4b. Alternative: sign in through the browser

Leave the token field empty to sign in with Facebook Login instead. This needs one extra setting:

1. In the left menu open **Facebook Login for Business > Settings**.
2. Under **Client OAuth settings** switch on **Client OAuth login** and **Web OAuth login** (and
   **Embedded browser OAuth login** if shown), and add this exact address to **Valid OAuth Redirect URIs**
   (newer screens show a **Redirect URI** box with a **Check URI** button):

   ```
   https://www.facebook.com/connect/login_success.html
   ```

3. Click **Save changes**.
4. In NEFORUM press **Sign in with Facebook**, log in, approve and **select your Page(s)**. You land on a
   nearly blank page that says *Success*. Copy the **whole address** from the address bar (it contains
   `#access_token=...`) and paste it into NEFORUM.

Facebook Login only redirects to registered HTTPS addresses, so `http://127.0.0.1:52771/callback` and
`neforum://callback` do not work here. Meta's manual login flow says desktop apps must use
`https://www.facebook.com/connect/login_success.html` with `response_type=token`, which is what NEFORUM does.

### 5. Publish the app so others can see your posts

Meta's App modes page says: "Any data generated while an app is in Development mode, such as test posts, can
only be seen by role users." So, once the connection works:

1. Click **Publish** in the left menu.
2. Provide what Meta asks for: an app icon (512 x 512 to 1024 x 1024 px, under 5 MB), a **Privacy Policy URL**,
   a **data deletion** URL (instructions or a callback) and, if you do business in the EU, a Data Protection
   Officer contact.
3. Click **Publish** in the lower-right corner.

App Review is a separate step (*Review > App Review*) and only matters for Advanced Access (see above).

Everything stays on your device: the App Secret, the user token and the Page token are kept in NEFORUM's
secret store. NEFORUM sends `appsecret_proof` with every call, so you can switch on
*App settings > Advanced > Require App Secret*.

## What NEFORUM posts

| Post | Graph call |
|---|---|
| Text, optionally with a link preview | `POST /{page-id}/feed` with `message` and `link` |
| One photo | `POST /{page-id}/photos`: multipart `source` upload with `caption` and `alt_text_custom`. No media host is needed. |
| 2 to 10 photos | each photo `POST /{page-id}/photos` with `published=false`, then `POST /{page-id}/feed` with `attached_media[n]={"media_fbid":"..."}` |
| One video | `POST /{page-id}/videos`: multipart `source` with `description` (and `title` if set) |
| Scheduled (when you let Facebook hold the schedule) | `published=false` + `scheduled_publish_time` on the same call. Multi-photo posts upload the photos with `published=false&temporary=true` and send `unpublished_content_type=SCHEDULED` on `/feed` (Page photos reference). |
| Taking a scheduled post back (you edit, reschedule, delete or "publish now") | `DELETE /{id}` with the Page token, where the id is the scheduled post (text, link and photo posts) or the video. A post that no longer exists (HTTP 404 or error 100/33) counts as removed. |

## Limits

* Text: 63,206 characters. Facebook does not document how it counts them; NEFORUM counts UTF-16 units.
  The feed shows *See more* after about 477 characters. Facebook has no threads, so long posts are not split.
* Photos: JPEG, PNG, GIF, BMP or TIFF, up to 10 MB each (keep PNGs under 1 MB to avoid pixelation). Up to
  10 per post in NEFORUM. Photos and video cannot be mixed in one post.
* Video: one per post, up to 1 GB and 20 minutes (the limit for non-resumable uploads).
* Photo posts cannot carry a link preview, so NEFORUM adds the link to the text.
* Scheduling on Facebook's side: "The publish date must be between 10 minutes and 30 days from the time of the
  API request" (Posts guide). NEFORUM hands a post over only when it is at least 15 minutes ahead, so that
  uploads and clock drift cannot push it under the minimum. Videos up to 180 days (the `/videos` reference says
  6 months). Anything outside that window is kept and published by NEFORUM itself, which needs the device to
  be on at that time.
* API budget (Graph API rate limiting): "Calls within 24 hours = 4800 * Number of Engaged Users".

## Troubleshooting

| What you see | What it means and what to do |
|---|---|
| "The token is missing pages_manage_posts ..." | The token was generated without that permission. Add it under **Use cases > Customize** if it is not there, add it in the Explorer's Permissions list, click **Generate Access Token** again and paste the new token. |
| "Facebook did not accept the pasted token" (error 190) | Explorer tokens are short-lived ("about one to two hours"). Generate a fresh one, for **your** app (Meta App dropdown), and paste all of it. |
| "This is a Page access token" | You chose your Page in *User or Page*. Choose **User Token**, generate again, paste. |
| "Facebook rejected the App ID/App Secret" (error 101 or 1) | Copy both again from **App settings > Basic**; the token must come from the same app. |
| "Facebook returned no Pages" | In the Facebook dialog you did not select a Page, or you have no Page role that can create content (task `CREATE_CONTENT`). Generate the token again and tick your Page. |
| "Invalid Scopes: business_management" | Remove `business_management` from NEFORUM's *Permissions (advanced)* field. |
| The browser says the redirect URI is not allowed | Add `https://www.facebook.com/connect/login_success.html` under **Facebook Login for Business > Settings** (step 4b) and save. Or use the Explorer token (step 4a). |
| Posts appear for you but nobody else sees them | The app is still in Development mode. **Publish** it (step 5). |
| Error 190 with subcode 458, 460, 463, 464 or 467 | App removed, password changed, token expired, unconfirmed account or invalid token. Reconnect. |
| Error 190 / 2069032 "A Page access token is required for this call" | The account was connected with a user token only. Reconnect so NEFORUM can store the Page token. |
| Error 1 / 2853006 or 492 | Your role on the Page does not allow this. Ask a Page admin for full control or content tasks. |
| Errors 10 or 200-299 | A permission is missing or was removed. Reconnect and grant everything. |
| Errors 4, 17, 32, 613, 80001 | Rate limit. NEFORUM waits (it reads `X-Business-Use-Case-Usage`) or falls back to hand-off. |
| Error 368, or subcode 1390008 | Facebook temporarily blocked posting (policy, or "posting too fast"). Wait. |
| Error 506 | The same text was just posted. Change it. |
| Error 1609005 | Facebook could not read the link. Check the URL. |
| Everything stopped after months of silence | Meta marks an app **Inactive** after 90 days with no logins, API calls or webhooks and invalidates its tokens. Reconnect (App states). |

## Known limitations

* **No personal profiles, no groups** through the API (see above). Use hand-off.
* **Hand-off cannot prefill text.** Meta deprecated `sharer.php?quote=` (NEFORUM still sends it in case it
  is honoured). The Android app keeps only the URL from shared text, the iOS share sheet drops text, and
  Meta's developer policy forbids prefilling. NEFORUM always puts your text on the clipboard.
  On a phone with photos or a video, the share sheet attaches them for you. With a link, the share window
  opens. Otherwise facebook.com (or your Page address) opens.
* **Reels** are not published yet (they need a separate 3-step upload; Meta caps them at 30 per Page per
  24 h). Videos are posted as regular Page videos.
* **Large videos** are sent in one request and held in memory. The resumable upload API is not used yet.
* **Disconnecting** does not revoke anything at Facebook, because revoking would also break other Pages
  connected through the same app. To revoke, remove the app under Facebook *Settings > Apps and websites*.
* Page tokens stop working when you change your Facebook password, lose your Page role or remove the app.
  NEFORUM then reports an auth error and you reconnect.
* Posts made through your app can only be edited or deleted by that same app ("An app can only update a Page
  post if the post was made using that app").

## Where Meta's documentation disagrees

* **Permissions for posting.** The permissions reference says `pages_manage_posts` depends on
  `pages_read_engagement` and `pages_show_list`, and the Video API publishing guide asks for exactly those
  three. The Pages *Get Started* page lists `pages_manage_metadata`, `pages_manage_posts`,
  `pages_manage_read_engagement` (a name that does not exist in the permissions reference) and
  `pages_show_list`. The *Posts* guide lists `pages_manage_engagement`, `pages_manage_posts`,
  `pages_read_engagement`, `pages_read_user_engagement` and `publish_video` (video only). NEFORUM asks for
  the reference set plus `business_management` (added by the use case by default). It does not ask for
  `publish_video`, because the Video API publishing guide does not require it for Page videos.
* **Page tasks.** *Get Started* needs only the `CREATE_CONTENT` task; the *Posts* guide lists `CREATE_CONTENT`,
  `MANAGE` and `MODERATE`. NEFORUM picks a Page on which you have `CREATE_CONTENT`.
* **Scheduling window.** The *Posts* guide says 10 minutes to 30 days; the `/feed` reference says 75 days.
  NEFORUM uses the safer 30.
* **Going live.** *App modes* says to switch to Live "after you have completed ... App Review", while the use-case
  *Publish* steps list only the icon, privacy policy, data deletion URL and DPO contact, and *Access levels* says
  Business apps get Standard Access automatically. For your own Page (you have a role on the app) the
  publish steps are enough.
* **Graph API Explorer labels.** The Explorer guide mentions the **Meta App** and **User or Page** dropdowns, a
  "Permission dropdown menu" and once says "Click **Get Access Token**"; the live tool's button reads
  **Generate Access Token**.

## Official documentation

New LLM-oriented pages (index: <https://developers.facebook.com/documentation/pages-api/llms.txt>):

* Pages API: <https://developers.facebook.com/documentation/pages-api>
* Overview (tokens, tasks, review): <https://developers.facebook.com/documentation/pages-api/overview>
* Create an app (use case customization): <https://developers.facebook.com/documentation/pages-api/create-an-app>
* Get started (Graph API Explorer, `/accounts`, first post): <https://developers.facebook.com/documentation/pages-api/getting-started>
* Posts (publish, schedule, delete): <https://developers.facebook.com/documentation/pages-api/posts>
* Error codes: <https://developers.facebook.com/documentation/pages-api/error-codes>
* Pages use case in the App Dashboard: <https://developers.facebook.com/documentation/development/create-an-app/pages-use-case>
* App roles: <https://developers.facebook.com/documentation/development/build-and-test/app-roles>
* App modes: <https://developers.facebook.com/documentation/development/build-and-test/app-modes>
* App states (inactive apps): <https://developers.facebook.com/documentation/development/create-an-app/app-dashboard/app-states>
* Access levels: <https://developers.facebook.com/documentation/development/graph-api/overview/access-levels>
* Access tokens: <https://developers.facebook.com/documentation/facebook-login/guides/access-tokens>
* Long-lived tokens: <https://developers.facebook.com/documentation/facebook-login/guides/access-tokens/get-long-lived>
* App Dashboard docs index: <https://developers.facebook.com/documentation/development/llms.txt>

Older reference pages NEFORUM also relies on:

* Graph API Explorer: <https://developers.facebook.com/docs/graph-api/explorer>
* Page feed / photos / videos reference: <https://developers.facebook.com/docs/graph-api/reference/page/feed/>,
  <https://developers.facebook.com/docs/graph-api/reference/page/photos/>,
  <https://developers.facebook.com/docs/graph-api/reference/page/videos/>
* Video publishing guide: <https://developers.facebook.com/docs/video-api/guides/publishing>
* Manual login flow (desktop redirect): <https://developers.facebook.com/docs/facebook-login/guides/advanced/manual-flow>
* Securing requests (appsecret_proof): <https://developers.facebook.com/docs/graph-api/securing-requests>
* Error handling: <https://developers.facebook.com/docs/graph-api/guides/error-handling>
* Rate limiting: <https://developers.facebook.com/docs/graph-api/overview/rate-limiting>
* Permissions reference: <https://developers.facebook.com/docs/permissions>
* Graph API v19.0 changelog (Groups API removal): <https://developers.facebook.com/docs/graph-api/changelog/version19.0>
* Sharing on Android / iOS: <https://developers.facebook.com/docs/sharing/android>, <https://developers.facebook.com/docs/sharing/ios>
* Share button / sharer: <https://developers.facebook.com/docs/plugins/share-button>

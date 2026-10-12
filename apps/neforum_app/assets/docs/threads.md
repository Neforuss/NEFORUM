# Threads (Meta)

*Last checked against Meta's developer documentation (the new `developers.facebook.com/documentation/threads`
pages and their `llms.txt` index) on 11 October 2026, and against Meta's App Dashboard during a real setup on the
same day. NEFORUM calls `graph.threads.net/v1.0`; since 6 June 2025 `graph.threads.com` works too.*

NEFORUM can post to Threads in two ways:

| Tier | What you need | Cost | Limits | Automatic? |
|---|---|---|---|---|
| **Your own API keys** (default) | A free Meta developer account and your own Meta app with the "Access the Threads API" use case | Free | 250 posts per profile per 24 h (a carousel counts once), 1,000 replies per 24 h | Yes |
| **Hand-off** | Nothing | Free | None | No: NEFORUM opens the Threads composer and you tap **Post** |

Status as of October 2026:

- Any Threads profile works. Threads has no business/creator split, and since 23 September 2025 profiles without a linked Instagram account can use the API too.
- **No App Review is needed** to post to your own profile. Your Threads profile only has to be a **Threads Tester** of your app: the *Get Started* page says Threads testers can grant the permissions at any time, while app users without a role need App Review and a published app.
- Meta has no paid tier and no price list for the Threads API.

## Option 1: your own Meta app (automatic posting)

### 1. Create the app

1. Open <https://developers.facebook.com/apps/creation/> and log in with the Facebook/Meta account you use for development. If asked, register as a developer (free).
2. Choose the use case **Access the Threads API**. This adds the Threads API to the app. Want Instagram too? Also tick **Manage messaging & content on Instagram**: one app can serve both Threads and Instagram (see the Instagram guide).
3. If the wizard asks *Which business portfolio do you want to connect to this app?*, you can pick **I don't want to connect a business portfolio yet**. That is fine for posting to your own profile.
4. Finish the wizard. The left menu may also list *Facebook Login for Business* even though you did not choose it. You can ignore it.

### 2. Permissions

In the left menu open **Use cases**, click **Access the Threads API** (or its pencil icon) and click **Add** next to:

- `threads_content_publish` (lets NEFORUM publish).

`threads_basic` is required and already shows "Ready for testing", so it needs no click. NEFORUM asks for nothing else.

### 3. Make your Threads profile a Threads Tester

Your developer login is a Facebook account; your Threads profile is a separate identity, so it needs its own role:

1. In the left menu open **App roles > Roles** (the button **Add or Remove Threads Testers** on the use case's **Settings** page leads there too).
2. Click **Add People**, choose **Threads Tester** and enter your Threads username.
3. Open Threads (app or website), go to **Settings > Account > Website permissions > Invites** and **accept** the invite (*Get Started*: the invite is accepted under Website permissions in the account settings of the Threads website or app, after signing in).

Repeat for every extra Threads profile you want to post to.

### 4a. Quickest: paste a token from the User Token Generator

1. In the left menu open the use case's **Settings** (*Use cases > Access the Threads API > Settings*). This is a different page from *App settings > Basic*.
2. Below the Threads app ID and secret is the **User Token Generator**. It says it makes long-lived access tokens for the app's Threads Testers, and only for **public** Threads accounts. It lists every tester who accepted the invite.
3. Make sure your Threads profile is public, then click **Generate Access Token** next to it. A pop-up opens: sign in to Threads if asked, allow access and copy the token.
4. In NEFORUM: **Add account > Threads > Your own API keys**, paste it into **Access token from the User Token Generator** (the first field). Leave the app ID, secret and redirect fields as they are.
5. Press the connect button. NEFORUM:
   - checks the token with `GET /v1.0/me` (your id and username);
   - asks Meta about it with `GET /v1.0/debug_token` (valid? which permissions? when does it expire?) and stops with a clear message if `threads_content_publish` is missing;
   - keeps a long-lived token as it is. Tokens from the User Token Generator are long-lived, so **no Threads app secret is needed**;
   - only if Meta reports a 1-hour token (for example one made with another tool) does NEFORUM ask for the **Threads app secret**, which it needs to swap the token for a 60-day one with `GET /access_token?grant_type=th_exchange_token`. If `debug_token` gives no answer, NEFORUM keeps the token as it is, unless you filled in the app secret: then it tries the swap first and keeps the pasted token if Meta refuses;
   - stores the token and renews it automatically (see "Tokens" below).

### 4b. Alternative: sign in through the browser

1. In the left menu open the use case's **Settings**. (This is a different page from *App settings > Basic*.)
2. Under **Redirect Callback URLs** (Meta's docs and some dashboards: **Client OAuth Settings**) add

   ```
   https://127.0.0.1:52771/callback
   ```

   Type it in, then **click the suggestion that appears** so the address turns into a grey "chip". Otherwise the page shows "Please enter an OAuth redirect URI".
3. Put the same address in **Uninstall Callback URL** and **Delete Callback URL** (Meta's docs and some dashboards: *Deauthorize callback URL* and *Data Deletion Requests URL*). Some dashboards do not save until all three are filled in.
4. Click **Save**.
5. Copy the **Threads app ID** and **Threads app secret** shown on that page (*App settings > Basic* shows them too, next to *Threads display name*). Meta creates two app ID/secret pairs for a Threads app; use the Threads app ID and its matching secret, **not** the Facebook App ID.
6. In NEFORUM paste both, leave the redirect URI as `https://127.0.0.1:52771/callback` (unless you registered something else) and press **Sign in with Threads**.
7. Threads opens in your browser. Sign in and allow access.
8. The browser lands on a page that does not load. Copy the **whole address** from the address bar. It looks like `https://127.0.0.1:52771/callback?code=AQB...#_` ("`#_` will be appended to the end of the redirect URI, but it is not part of the code itself"; NEFORUM strips it). Paste it into NEFORUM. A bare code also works.

Why this address? NEFORUM's desktop sign-in normally listens on `http://127.0.0.1`, and on phones it uses `neforum://callback`, but Meta's dashboard only takes `https://` redirect addresses for Threads (Meta's sample app README and issue #32). Nothing answers at `https://127.0.0.1:52771/callback`, so your browser shows an error page. **That is expected.** Meta: "Make sure this exactly matches one of the base URIs in your list of valid OAuth URIs", including a trailing `/` if the dashboard added one; you may register any other `https://` address you control and enter it in NEFORUM's *Redirect URI you registered* field.

"Authorization codes are valid for 1 hour and can only be used once." If something fails, start the connection again for a fresh code.

### Tokens

- Short-lived tokens (from the sign-in code) last 1 hour; NEFORUM immediately swaps them for long-lived tokens, which are valid for 60 days.
- NEFORUM renews the token with `GET /refresh_access_token?grant_type=th_refresh_token` before publishing, once it is at least 24 hours old ("at least 24 hours old but have not expired"). Each refresh gives another 60 days. No app secret is needed for this.
- "Tokens that have not been refreshed in 60 days will expire and can no longer be refreshed." If you do not post through the account for 60 days, connect again.
- Granted permissions last 90 days and are extended by refreshing the token. For private profiles the pages disagree (see the end of this guide); if NEFORUM reports a permission error after 90 days, connect again.
- A pasted token whose age NEFORUM cannot learn is renewed for the first time 24 hours after you connect it.

### Images and videos need a media host

The Threads API has no upload endpoint. Meta downloads every image and video from a **public HTTPS address** when the post is created, so it must be on a publicly accessible server at that moment (*Get Started*). Before you post media, configure a media host in NEFORUM under **Settings > Media hosting**:

- **To start:** pick **Litterbox**. It needs no account and no setup. It is a free service run by a volunteer, with no guarantee: uploads can fail when its server has problems.
- **For regular posting:** use a storage bucket you own (Backblaze B2, Cloudflare R2, Amazon S3) or a Nextcloud/WebDAV share. A bucket is the most reliable choice.
- The media hosting guide explains each host step by step. In NEFORUM it is the **Guide** button under *Settings > Media hosting*; in the repository it is `docs/media-hosts.md`.

When you post media, NEFORUM:

1. uploads each file to your host,
2. hands Meta the address,
3. waits until Meta reports the media as processed (Meta suggests waiting about 30 seconds on average and querying the status "once per minute, for no more than 5 minutes"; NEFORUM checks for up to 5 minutes),
4. publishes, and
5. deletes the files from your host again (best effort; Litterbox files expire by themselves instead).

The host must serve the file directly. Redirects, link shorteners, "are you a bot?" pages and links that expire within minutes all make Meta's download fail. Text-only posts need no media host.

## Option 2: hand-off (no setup)

NEFORUM opens `https://www.threads.com/intent/post?text=…` with your text prefilled. This is the web composer on desktop; on phones the link opens the Threads app if it is installed. You check the post and tap **Post**. The older `threads.net/intent/post` address still redirects to `threads.com`.

- A link attachment, a topic tag and the reply setting can be prefilled.
- **Images and videos cannot be prefilled** by the web link. On a phone, NEFORUM uses the system share sheet (Threads: Android package `com.instagram.barcelona`), and your text is also put on the clipboard in case Threads drops it. On a computer, drag the files into the composer.
- For threads (several posts), only the first part is prefilled. The full text is on your clipboard, so you can paste the rest with **Add to thread**.

## What NEFORUM supports

All numbers are from the Threads *Posts* guide and the *Troubleshooting* page:

- Text posts up to **500 characters**. "Emojis are counted as the number of UTF-8 bytes" (a typical emoji counts as 4). NEFORUM warns when emoji push a post over the limit.
- Long texts are published as a **thread**: each part is a reply to the previous one. Media goes on the first post.
- **One image or video**, or a **carousel of 2–20** images and videos (mixed is fine).
  - Images: JPEG or PNG, up to 8 MB, 320–1440 px wide (Meta scales others), aspect ratio up to 10:1, sRGB.
  - Videos: MOV or MP4 (moov atom at the front, H.264/HEVC, AAC audio), up to 5 minutes (300 s) and 1 GB, 23–60 fps, at most 1920 px wide, aspect ratio 0.01:1 to 10:1 (9:16 recommended).
- **Alt text** (up to 1,000 characters) for every image and video.
- The "sensitive" flag marks media as a spoiler.
- **Link preview:** for text-only posts, the post's link is sent as `link_attachment` (link attachments only work on text-only posts). Since 22 December 2025 posts with more than 5 links fail with `THREADS_API__LINK_LIMIT_EXCEEDED`.
- Per-post options (advanced; post overrides or account defaults):
  - `topic_tag`: one topic per post, 1–50 characters, no `.` or `&`.
  - `reply_control`: one of `everyone`, `accounts_you_follow`, `mentioned_only`, `parent_post_author_only`, `followers_only`.

## Troubleshooting

| What you see | What it means and what to do |
|---|---|
| The Threads sign-in window shows an error, or "The user has not accepted the invite to test the app" (error 1349245, reported by developers) | Your Threads profile is not a Threads Tester yet, or the invite is not accepted. Do step 3. |
| The User Token Generator does not list your profile, or **Generate Access Token** fails | Accept the Threads Tester invite (step 3) and make your Threads profile public. The generator only makes tokens for public profiles. |
| "Threads refused the sign-in code ... Invalid redirect_uri" | The redirect URI in NEFORUM does not match the one under **Redirect Callback URLs** (or **Client OAuth Settings**) exactly (watch the trailing `/`), or you used the Facebook App ID instead of the Threads app ID. |
| "Error validating client secret" / session key errors | You pasted the Facebook App Secret. Use the **Threads app secret** from the use case's Settings page. |
| "The code has been used" / "code not found" | Codes work once and for 1 hour. Start the connection again. |
| "This token cannot publish: add threads_content_publish" | Add the permission (section 2), then generate a new token. |
| "This token only lasts about an hour" | Also fill in the Threads app secret so NEFORUM can swap it for a 60-day token, or paste a token from the User Token Generator instead (those are long-lived). |
| Error 190 ("Error validating access token") | The token expired or was revoked (or cut off when pasting). Reconnect. |
| Error 10 or 200–299 | A permission is missing. Reconnect and allow `threads_content_publish`. |
| Errors 4, 17, 32, 613 or HTTP 429 | Rate limit. NEFORUM waits and retries. `GET /{user-id}/threads_publishing_limit` shows the quota (250 posts, 1,000 replies, 100 deletes per 86,400 s). |
| Container status `ERROR` with `FAILED_DOWNLOADING_VIDEO` | Meta could not fetch the file from your media host. Make it public, direct and HTTPS. |
| `INVALID_ASPEC_RATIO`, `INVALID_DURATION`, `INVALID_FRAME_RATE`, `INVALID_BIT_RATE`, ... | The video breaks one of the specs above. Re-encode it. |
| Container status `EXPIRED` | "The container was not published within 24 hours". Try again. |
| Other people do not see your posts | Meta's general App modes rule is that data created by an app in Development mode "can only be seen by role users". If that happens, **Publish** the app (left menu). As of October 2026 the only required item was a **Privacy policy URL**; an app icon and a data deletion URL were optional. |
| Everything stopped after months of silence | Meta marks an app **Inactive** after 90 days with no logins, API calls or webhooks and invalidates its tokens. Reconnect. |

## Known limitations

- **No server-side scheduling.** Scheduled posts are sent by NEFORUM at the scheduled time, so the app (or the NEFORUM CLI) has to be running then.
- **Copy-paste sign-in.** Meta only allows HTTPS redirect addresses, so NEFORUM cannot catch the sign-in redirect automatically. You paste the address once per connection (or paste a token instead), and again only if the token expires.
- **Media needs a public host** (see above). GIFs are not supported: the API only takes GIFs as GIPHY stickers, which NEFORUM does not offer.
- **Rate limits:** 250 published posts and 1,000 replies per profile per rolling 24 hours. NEFORUM counts each part of a thread against the 250, which is conservative.
- The **hand-off** tier cannot attach media on desktop, and on phones it depends on the Threads app's share target.
- If you share Threads posts to the fediverse in the Threads app, posts published through the API are federated too.

## Where Meta's documentation disagrees

- **Settings field names.** Both naming styles exist. The *Create an app* / *Threads use case* pages name the fields **Client OAuth Settings**, **Deauthorize callback URL** and **Data Deletion Requests URL**. The dashboard in October 2026 showed *Redirect Callback URLs*, *Uninstall Callback URL* and *Delete Callback URL*, next to *Threads app ID*, *Threads app secret* and *Threads Display Name*. Same fields.
- **Where the Threads app secret is.** The use-case pages show it under the use case's **Settings**; the *Long-lived tokens* page says *App Dashboard > App settings > Basic > Threads App secret*. In October 2026 both places showed it (*App settings > Basic* lists the Threads app ID, Threads app secret and Threads display name).
- **Token exchange host.** The *Get access tokens* page uses `https://graph.threads.com/oauth/access_token`, the *Long-lived tokens* page `https://graph.threads.net/access_token`. The changelog (6 June 2025) says both hosts work; NEFORUM uses `graph.threads.net`.
- **HTTPS redirects.** The access-token pages only say the redirect must match exactly and use HTTPS examples; the HTTPS-only rule comes from Meta's sample app and its issue tracker.
- **Testers.** The changelog says the API "is open to all developers" since 18 June 2024; the *Get Started* page still says people without a role need App Review. For your own profile the Threads Tester role covers both readings.
- **Private profiles.** *Get Started* says permission grants from private profiles cannot be extended and must be granted again; *Long-lived tokens* says private-profile tokens can now be refreshed and their permissions are valid for 90 days.
- **User Token Generator.** None of Meta's current Threads pages mention it, but it was on the use case's Settings page in October 2026 (step 4a), making long-lived tokens for public profiles. NEFORUM still checks every pasted token itself (`/me` and `debug_token`) instead of assuming how long it lasts.

## Official documentation

New LLM-oriented pages (index: <https://developers.facebook.com/documentation/threads/llms.txt>):

- Threads API: <https://developers.facebook.com/documentation/threads>
- Get started (permissions, tokens, Threads testers): <https://developers.facebook.com/documentation/threads/get-started>
- Create an app: <https://developers.facebook.com/documentation/threads/get-started/create-an-app>
- Threads use case in the App Dashboard: <https://developers.facebook.com/documentation/development/create-an-app/threads-use-case>
- Get access tokens (authorization window, code exchange): <https://developers.facebook.com/documentation/threads/get-started/get-access-tokens-and-permissions>
- Long-lived tokens (exchange and refresh): <https://developers.facebook.com/documentation/threads/get-started/long-lived-tokens>
- Debug access token: <https://developers.facebook.com/documentation/threads/troubleshooting/debug-access-token>
- Posts (limits, media specs, carousels, links): <https://developers.facebook.com/documentation/threads/posts>
- Publishing reference: <https://developers.facebook.com/documentation/threads/reference/publishing>
- Troubleshooting (publishing limits, container statuses): <https://developers.facebook.com/documentation/threads/troubleshooting>
- Web intents: <https://developers.facebook.com/documentation/threads/threads-web-intents>
- Changelog: <https://developers.facebook.com/documentation/threads/changelog>
- App roles / App modes / App states: <https://developers.facebook.com/documentation/development/build-and-test/app-roles>, <https://developers.facebook.com/documentation/development/build-and-test/app-modes>, <https://developers.facebook.com/documentation/development/create-an-app/app-dashboard/app-states>

Other sources: Threads permissions reference <https://developers.facebook.com/docs/permissions/threads>; HTTPS-only redirect URIs (Meta sample README and issue #32) <https://github.com/fbsamples/threads_api>, <https://github.com/fbsamples/threads_api/issues/32>.

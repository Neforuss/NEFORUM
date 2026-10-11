# Reddit

NEFORUM can reach Reddit in two ways. You pick one when you add the account, and you can add the same Reddit account once for each.

| | **Your own API keys** (default) | **Hand-off** |
|---|---|---|
| What happens | NEFORUM posts for you: text, link, image, gallery and video posts, even on a schedule | NEFORUM opens Reddit's *Create post* page with the title and text (or link) filled in, and you press **Post** |
| What you need | Any Reddit account, plus your own Reddit **installed app** (a client ID) that Reddit has approved | Any Reddit account and a browser, or the Reddit app on your phone |
| Cost | Free for personal, non-commercial use | Free |
| Review | **Yes, since November 2025.** See below | None |
| Limits | 100 API requests per minute per app. Reddit also has its own anti-spam limits for each account | One post at a time |

## Status as of October 2026: API access needs approval

- On **11 November 2025** Reddit closed self-service access to its Data API and introduced the **Responsible Builder Policy**. Anyone who wants *new* API access (developers, researchers, moderators) now has to ask Reddit for approval first. Reddit staff said they aim to answer most requests within 7 days. Developers report that requests from small and personal projects are often declined.
- **Apps that already existed keep working.** Reddit said current access is not affected for anyone acting within its policies.
- Since then, developers report that **reddit.com/prefs/apps** often shows only the policy page, or seems to create an app that then doesn't work. NEFORUM can't check whether your app is approved. If the connection fails with "unauthorized" or HTTP 401/403, your app probably isn't approved.
- **If you don't have a working app, use Hand-off.** It needs no approval at all.
- Approved apps keep the old terms: the API is free for non-commercial use, up to **100 requests per minute per client ID**. Reddit charges $0.24 per 1,000 calls only to apps that need more than that. Reddit's Data API terms forbid commercial use without its written approval, and forbid using Reddit data to train AI models.

Each NEFORUM user registers their **own** client ID. That means you get your own 100 requests per minute instead of sharing them with every NEFORUM user. NEFORUM counts every post as one request (`reddit.requests_per_minute`). In reality an image post takes about 4 requests and a video about 6, so the counter is only a safety net.

## Set up your own Reddit app (once, about 5 minutes)

1. Sign in to Reddit in your browser and open **https://www.reddit.com/prefs/apps**. If you only see the Responsible Builder Policy, you first have to request access through the form Reddit links to there. Describe NEFORUM as a personal, open-source (GPL-3.0) cross-posting app that only posts what you write, to subreddits you choose.
2. Press **create another app…** (or **are you a developer? create an app…**).
3. Fill in the form:
   - **name:** `NEFORUM` (or anything you like)
   - **type:** choose **installed app**. Don't choose *script*: a script app can only sign in with your password. Don't choose *web app*: it needs a secret that NEFORUM can't keep.
   - **description / about url:** optional. For example `https://github.com/neforum-app/neforum`
   - **redirect uri:** enter exactly
     - `http://127.0.0.1:52771/callback` for NEFORUM on **Windows and macOS**, or
     - `neforum://callback` for NEFORUM on **Android and iOS**.

     A Reddit app has **only one** redirect uri, and Reddit compares it character for character. If you use NEFORUM on a computer *and* a phone, create two installed apps (one per redirect uri), or connect from a computer.
4. Press **create app**. The **client ID** is the short code right under the words *installed app* at the top of the app box. An installed app has no secret.
5. In NEFORUM: **Add account → Reddit → Your own API keys**. Paste the client ID. If you like, also enter a default subreddit (without `r/`; use `u_yourname` to post on your own profile). Then press **Connect**.
6. Your browser opens Reddit's consent page (a compact version on phones). Press **Allow**, and NEFORUM shows `u/yourname`.

NEFORUM asks for these permissions: `identity` (your username), `submit` (posting and commenting), `read`, `mysubreddits` (your communities, for choosing one), `flair` (post flair). It asks for a **permanent** sign-in (`duration=permanent`) so that it can renew the one-hour access token by itself.

### Where things are stored

- The client ID, your username and the default subreddit are stored with the account settings.
- The access token (valid for 1 hour) and the refresh token are stored in your device's secret store. NEFORUM renews the access token automatically.
- Removing the account in NEFORUM revokes the refresh token at Reddit (`/api/v1/revoke_token`).
- Every request identifies NEFORUM with a User-Agent of the form `<platform>:org.neforum.app:v0.1.0 (by /u/yourname)`, as Reddit's API rules require.

## What gets posted

Every Reddit post goes to **one subreddit** and needs a **title**:

- **Subreddit:** taken from the post's own setting, otherwise from the account's default. You can type `pics`, `r/pics` or `u/yourname` (your profile).
- **Title:** up to 300 characters. If you leave it empty, NEFORUM uses the first line of your text.
- **Text post:** the body is sent as Markdown, up to 40,000 characters. Reddit has no threads, so long text is never split.
- **Link post:** used when the post has a link and no media. The link is the post. Your text (if any) is added as **your first comment**, because Reddit link posts have no body. Comments can hold up to 10,000 characters. If you don't want the comment, set the per-post option `bodyAsComment` to `false`.
- **Image post:** 1 image. **Gallery:** 2 to 20 images. JPEG, PNG or GIF only (no WebP), 20 MB each. A gallery carries your text as its body. On a single-image post the text becomes the first comment. If a media post also has a link, the link is added to the text.
- **Video post:** 1 MP4 or MOV video (Reddit Help says up to 1 GB and 15 minutes). Reddit needs a thumbnail. Set the per-post option `videoPoster` to the path of an image, or NEFORUM uploads a plain dark 16:9 image (PRAW, the popular Python library, does the same with its logo). Set `videogif: true` for a silent looping "GIF" video. You can't mix images and video in one post.
- **NSFW** is set when the post is marked sensitive. A **content warning** turns on Reddit's **spoiler** tag. The warning text itself is not sent.
- **Per-post options:** `subreddit`, `flairId` (up to 36 characters), `flairText` (up to 64), `nsfw`, `spoiler`, `sendReplies` (default true), `resubmit` (default true, so the same link can go to several subreddits), `bodyAsComment`, `videoPoster`, `videogif`.
- **Alt text:** the Reddit API has no alt-text field, so image descriptions are not sent.
- **Scheduling:** the Data API cannot schedule posts. NEFORUM keeps the schedule itself, so your device has to be on and online at posting time.

### Image and video uploads (how it works)

Reddit has no documented upload endpoint, so NEFORUM uses the same flow that PRAW and Infinity for Reddit use:

1. `POST /api/media/asset.json` gets an upload slot.
2. The file goes to Reddit's Amazon S3 bucket, with every field of the slot in order and the file last.
3. `POST /api/submit` with `kind=image` or `kind=video`, or `POST /api/submit_gallery_post.json` for galleries.
4. For image and video posts Reddit only reports the new post on a WebSocket once processing is done. NEFORUM waits up to 90 seconds. If the WebSocket fails, the post was most likely still created, and NEFORUM links to your *Submitted* page instead of the post itself.

## Errors you may see

- **"you are doing that too much. try again in N minutes"**: Reddit's anti-spam limit, which is common for new or low-karma accounts. NEFORUM reports it as a quota problem and retries after the time Reddit gives.
- **Rate limit (HTTP 429):** more than 100 requests in a minute from your app. NEFORUM waits for the reset time Reddit reports (`X-Ratelimit-Reset`).
- **SUBREDDIT_NOTALLOWED / NO_SELFS / NO_LINKS / flair required / title rules:** the subreddit's own rules. Fix the post, for example by adding a flair id or choosing another community.
- **CAPTCHA:** Reddit sometimes asks new accounts to solve a CAPTCHA. The API can't do that, so post that one through hand-off.
- **HTTP 401 / 403:** the sign-in expired or was revoked, the account is suspended, or your app isn't (or is no longer) approved. Reconnect. If that fails, use hand-off.

## Hand-off

NEFORUM opens `https://www.reddit.com/r/<subreddit>/submit?title=…&text=…`, or `?title=…&url=…` for link posts. Without a subreddit it opens `https://www.reddit.com/submit?…` and you pick the community there. Your text is always copied to the clipboard as well.

- **Android:** with images or video, the share sheet hands the files to the Reddit app (`com.reddit.frontpage`). The title and text are on the clipboard.
- **iOS:** Reddit's app claims `reddit.com/submit` links, so the composer opens in the app when it's installed and in Safari otherwise.
- **Windows / macOS:** the browser composer. Attach images and videos by hand.
- You have to be signed in to Reddit in the browser, or you land on the login page first.

## Known limitations

- **New API apps need Reddit's approval** (see above). Without one, only hand-off works.
- The image/video upload flow and the gallery endpoint are **undocumented**. Reddit could change them without notice.
- Prefilling the **body** through `?text=` on the submit page couldn't be verified (Reddit's pages block automated checks). The link (`?url=`) and title prefills are verified. If the body is missing, paste it from the clipboard.
- That `http://127.0.0.1:52771/callback` is accepted as a redirect uri is based on Reddit's documentation that installed apps may use "an arbitrary URI". Only `http://localhost:8080` has been confirmed by others. If Reddit refuses it, tell us.
- That profile posts use `u_yourname` as the subreddit is common practice, but Reddit doesn't document it.
- The image (20 MB) and video (1 GB, 15 minutes) limits come from Reddit Help pages that couldn't be read directly.
- NEFORUM can't check the subreddit's rules (required flair, banned domains) before posting.
- NEFORUM loads each file into memory to upload it, so very large videos may fail on phones.
- Polls, crossposts, inline images inside text posts and editing posts are not supported.

## Sources

- https://www.reddit.com/dev/api/oauth (endpoint reference: `/api/submit`, `/api/comment`, scopes)
- https://github.com/reddit-archive/reddit/wiki/OAuth2 (authorize, token, refresh and revoke)
- https://github.com/reddit-archive/reddit/wiki/OAuth2-App-Types (installed apps, redirect URIs)
- https://github.com/reddit-archive/reddit/wiki/API (User-Agent rules, rate-limit headers)
- https://support.reddithelp.com/hc/en-us/articles/42728983564564-Responsible-Builder-Policy
- r/redditdev, "Introducing the Responsible Builder Policy" (Reddit staff, 11 November 2025): https://www.reddit.com/r/redditdev/comments/1oug31u/
- r/reddit, "Addressing the community about changes to our API" (June 2023: 100 QPM per client ID, $0.24 per 1,000 calls): https://www.reddit.com/r/reddit/comments/145bram/
- PRAW `Subreddit.submit_image` / `submit_video` / `submit_gallery` (media lease flow): https://github.com/praw-dev/praw/blob/v7.8.1/praw/models/reddit/subreddit.py
- Infinity for Reddit (gallery payload, media upload): https://github.com/Docile-Alligator/Infinity-For-Reddit
- https://www.reddit.com/.well-known/apple-app-site-association (iOS universal link for `/submit`)
- https://play.google.com/store/apps/details?id=com.reddit.frontpage

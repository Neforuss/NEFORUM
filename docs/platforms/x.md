# X (Twitter)

NEFORUM can reach X in two ways. Pick one when you add the account. You can also add the same X account twice, once for each way.

| | **Your own API keys** (default) | **Hand-off** |
|---|---|---|
| What happens | NEFORUM posts for you, threads and media included, even when it runs on a schedule | NEFORUM opens the X composer with your text filled in, and you press **Post** |
| What you need | Any X account, plus your own free X developer app with credits on it | Any X account. The X app on your phone, or a browser |
| Cost | Pay-per-use: about **$0.015 per post**, or **$0.20 per post that contains a link**, paid to X from your own credits | Free |
| Review | None. Self-serve apps can post as soon as they are created and funded | None |
| Limits | 100 posts per 15 minutes per user, 10,000 per 24 hours per app | One post at a time. Threads have to be posted by hand |

## What changed in 2026 (status as of October 2026)

- **No free tier for new developers.** On 6 February 2026 X closed its Free API tier to new sign-ups and moved everyone to **pay-per-use** credits. Developers who were still using the old Free tier got a one-time $10 voucher and were moved over too. The old Basic plan ($200 a month) was closed to new sign-ups and has been migrated to pay-per-use since 1 June 2026.
- **Prices** (from X's pricing page): creating a post costs $0.015 per request, and a post containing a URL costs $0.20. You are only billed for requests that succeed. Credits do not expire and cannot be refunded (EU/UK buyers have a 14-day withdrawal right). You can set a monthly spending limit and auto-recharge in the console.
- **Starter credit:** X's changelog (2 October 2026) describes a one-time free credit when you save an eligible payment card. Check the console for the current offer.
- Quote posts, likes and follows were removed from all self-serve API access in April 2026. NEFORUM does not use them.

NEFORUM keeps its own count of the posts it sends so it can warn you before X refuses. The monthly counter (`x.posts_per_month`) starts at **500**, which mirrors the old Free tier. Pay-per-use has no fixed monthly cap, only your credits and spending limit, so you can raise this number in the account's settings.

## Set up your own X app (once, about 10 minutes)

1. Go to **https://console.x.com** and sign in with the X account you want to post from (or any account you own). Accept the Developer Agreement and the pay-per-use terms.
2. Open billing and **buy credits**. A few dollars covers hundreds of text posts. If you like, set a monthly spending limit.
3. Create a **Project**, then create an **App** inside it.
4. Open the app's **User authentication settings** and set up **OAuth 2.0**:
   - **App permissions:** *Read and write*
   - **Type of app:** *Native App*. This is a public client and needs no secret. *Web App* and *Automated App or Bot* also work, but then you have to paste the Client Secret into NEFORUM too.
   - **Callback URI / Redirect URL:** add **both** of these, character for character:
     - `http://127.0.0.1:52771/callback` (used by NEFORUM on Windows and macOS)
     - `neforum://callback` (used by NEFORUM on Android and iOS)

     X compares them exactly: no trailing slash, and `localhost` is **not** accepted (use `127.0.0.1`). An app can have up to 10 callback URLs.
   - **Website URL:** any page about you, or `https://github.com/neforum-app/neforum`.
5. Save. Then open **Keys and tokens** and copy the **OAuth 2.0 Client ID**. If you chose a confidential app type, copy the **Client Secret** as well.
6. In NEFORUM: **Add account → X → Your own API keys**, paste the Client ID, and press **Connect**. Your browser opens X and asks you to authorise the app. After you approve, NEFORUM shows your name and @handle.

NEFORUM asks X for these permissions: `tweet.read tweet.write users.read media.write offline.access`. `offline.access` lets NEFORUM renew the two-hour sign-in in the background, so you don't have to log in again every time.

### Where things are stored

- The Client ID is stored with the account settings.
- The access token, the refresh token and the optional Client Secret are stored in your device's secret store.
- X replaces the refresh token every time it is used. If NEFORUM reports that X "refused to renew the sign-in", reconnect the account.
- Removing the account in NEFORUM revokes the token at X.

## What gets posted

- **Text:** up to 280 characters, counted the way X counts them. Most Latin, Greek and Cyrillic characters count as 1. Chinese, Japanese and Korean characters and every emoji count as 2. Every link counts as 23, however long it is. Longer text is split into a numbered **thread**: each part is posted as a reply to the one before it.
- **Long posts:** posts over 280 characters only work if the posting account has X Premium. NEFORUM can't tell whether you have Premium, so it always splits long text into a thread.
- **Media:** up to 4 photos (JPEG, PNG, WEBP or static GIF, 5 MB each), *or* 1 animated GIF (15 MB), *or* 1 video (MP4/MOV, up to 20 minutes and 8 GB, longer with Premium). You can't mix photos and video in one post. Media is attached to the first post of a thread.
- **Alt text:** sent for every photo or GIF that has it, up to 1000 characters.
- **Who can reply:** you can set the per-post option `replySettings` to `following`, `mentionedUsers`, `subscribers` or `verified`.
- **Scheduling:** the X API cannot schedule posts. NEFORUM keeps the schedule itself, so the device has to be on and online at posting time. Media is uploaded at posting time, because X only keeps uploads for 24 hours.

## Hand-off

NEFORUM opens `https://x.com/intent/tweet?text=…&url=…`. That is X's documented web intent, and it fills in the text for you. Your full text is also copied to the clipboard.

- **Android:** the share sheet sends text and up to 4 photos or 1 video to the X app (`com.twitter.android`).
- **iOS:** the system share sheet hands text and media to the X app.
- **Windows / macOS:** X has no desktop share target, so the browser composer gets the text only. Attach photos and videos yourself.
- Threads can't be prefilled. Post the first part, then reply to it and paste each following part from the clipboard.

## Known limitations

- Every API post costs money from your own X credits, and NEFORUM can't see your balance. When X answers "CreditsDepleted" (HTTP 402), NEFORUM reports a quota problem and can fall back to hand-off.
- X refuses identical text posted twice in a short time ("duplicate content"). Its developer policy also forbids posting identical or very similar content across several accounts.
- If a thread fails part-way, NEFORUM tells you which parts were already posted and does not retry automatically, because a retry would duplicate them.
- NEFORUM loads the whole video into memory before uploading it, so multi-gigabyte videos may fail on phones.
- The `neforum://callback` redirect is not explicitly documented by X. X's rules only list forbidden schemes, and custom schemes have worked in the past. If the console refuses it, sign in from a computer using the `127.0.0.1` address.
- Polls, communities, quote posts and editing posts are not supported.

## Sources

- https://docs.x.com/x-api/getting-started/pricing
- https://docs.x.com/changelog
- https://docs.x.com/x-api/posts/creation-of-a-post
- https://docs.x.com/x-api/media/upload-media
- https://docs.x.com/x-api/media/quickstart/media-upload-chunked
- https://docs.x.com/x-api/media/get-media-upload-status
- https://docs.x.com/x-api/media/metadata-create
- https://docs.x.com/x-api/media/quickstart/best-practices
- https://docs.x.com/x-api/fundamentals/rate-limits
- https://docs.x.com/resources/fundamentals/authentication/oauth-2-0/authorization-code
- https://docs.x.com/resources/fundamentals/authentication/oauth-2-0/user-access-token
- https://docs.x.com/resources/fundamentals/developer-apps
- https://docs.x.com/resources/fundamentals/counting-characters
- https://docs.x.com/x-for-websites/post-button/guides/web-intent
- https://docs.x.com/developer-terms/policy
- https://docs.x.com/developer-terms/ppu-agreement

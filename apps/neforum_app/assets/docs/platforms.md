# Platform support

NEFORUM reaches every platform in one of three ways. Each account you connect uses one of them, and you can connect the same platform more than one way.

- **Auto** (open API): posts automatically. No developer keys, no fees, no review.
- **Your keys** (official API with your own developer app): posts automatically within the platform's quota. You create a free (or, for X, pay-per-use) developer app once.
- **Hand-off**: NEFORUM prepares the post, copies the text and opens the platform's app or website; you tap Post. Works with any personal account, even where the API is closed to normal users.

Generated from the code on 2026-10-17.

| Platform | Ways to post | Personal account OK | Text limit | Media | Quotas tracked | Server-side scheduling | Setup guide |
|---|---|---|---|---|---|---|---|
| BitChute | Hand-off | Yes | 3000 characters | 1 video (required) | - | - | [bitchute.md](platforms/bitchute.md) |
| Bluesky | Auto, Hand-off | Yes | 300 characters, threads | 4 images or 1 video | 1666/1 h, 11666/day | - | [bluesky.md](platforms/bluesky.md) |
| DEV Community | Auto, Hand-off | Yes | 819200 bytes | 10 images, needs media host for API | 10/30 s | - | [devto.md](platforms/devto.md) |
| Discord | Auto | Yes | 2000 characters, threads | 10 images or 10 videos | 30/1 min | - | [discord.md](platforms/discord.md) |
| Facebook | Your keys, Hand-off | Hand-off only | 63206 characters | 10 images or 1 video | 4800/day | Yes | [facebook.md](platforms/facebook.md) |
| Ghost | Auto, Hand-off | Yes | No limit | 20 images | - | Yes | [ghost.md](platforms/ghost.md) |
| Google Business Profile | Hand-off | Hand-off only | 1500 characters | 1 image or 1 video | - | - | [google_business.md](platforms/google_business.md) |
| Hashnode | Your keys, Hand-off | Yes | No limit | 10 images | 500/1 min | - | [hashnode.md](platforms/hashnode.md) |
| Instagram | Your keys, Hand-off | Hand-off only | 2200 characters | 10 images or 10 videos (required), needs media host for API | 100/day | - | [instagram.md](platforms/instagram.md) |
| Lemmy | Auto, Hand-off | Yes | 50000 characters | 1 image or 1 video | 6/10 min | - | [lemmy.md](platforms/lemmy.md) |
| LinkedIn | Your keys, Hand-off | Yes | 3000 characters | 20 images or 1 video | 150/day | - | [linkedin.md](platforms/linkedin.md) |
| Mastodon | Auto, Hand-off | Yes | 500 characters (links = 23), threads | 4 images or 1 video | 300/5 min, 1000/day | Yes | [mastodon.md](platforms/mastodon.md) |
| Matrix | Auto | Yes | No limit | 10 images or 10 videos | 12/1 min | - | [matrix.md](platforms/matrix.md) |
| Micropub (IndieWeb / Micro.blog) | Auto | Yes | No limit | 10 images or 1 video | - | - | [micropub.md](platforms/micropub.md) |
| Misskey | Auto, Hand-off | Yes | 3000 characters, threads | 16 images or 16 videos | 300/1 h | - | [misskey.md](platforms/misskey.md) |
| Nostr | Auto, Hand-off | Yes | No limit | 20 images or 20 videos | - | - | [nostr.md](platforms/nostr.md) |
| Odysee | Auto, Hand-off | Yes | 5000 characters | 1 image or 1 video (required) | - | - | [odysee.md](platforms/odysee.md) |
| Pinterest | Your keys, Hand-off | Hand-off only | 800 characters | 5 images or 1 video (required) | 300/day, 1000/day | - | [pinterest.md](platforms/pinterest.md) |
| Reddit | Your keys, Hand-off | Yes | 40000 characters | 20 images or 1 video | 100/1 min | - | [reddit.md](platforms/reddit.md) |
| Rumble | Hand-off | Yes | 5000 characters | 1 video (required) | - | - | [rumble.md](platforms/rumble.md) |
| Snapchat | Hand-off | Yes | 250 characters | 1 image or 1 video (required) | - | - | [snapchat.md](platforms/snapchat.md) |
| Substack Notes | Hand-off | Yes | No limit | 6 images or 1 video | - | - | [substack.md](platforms/substack.md) |
| Telegram | Auto, Hand-off | Yes | 4096 characters, threads | 10 images or 10 videos | 20/1 min | - | [telegram.md](platforms/telegram.md) |
| Threads | Your keys, Hand-off | Yes | 500 characters, threads | 20 images or 20 videos, needs media host for API | 250/day | - | [threads.md](platforms/threads.md) |
| TikTok | Your keys, Hand-off | Yes | 2200 characters | 35 images or 1 video (required) | 15/day, 6/1 min | - | [tiktok.md](platforms/tiktok.md) |
| Tumblr | Your keys, Hand-off | Yes | 524288 characters | 30 images or 1 video | 250/day | Yes | [tumblr.md](platforms/tumblr.md) |
| WhatsApp | Hand-off | Yes | No limit | 100 images or 100 videos | - | - | [whatsapp.md](platforms/whatsapp.md) |
| WordPress | Auto, Hand-off | Yes | No limit | 20 images or 5 videos | - | Yes | [wordpress.md](platforms/wordpress.md) |
| Write.as / WriteFreely | Auto, Hand-off | Yes | No limit | 20 images, needs media host for API | - | - | [writefreely.md](platforms/writefreely.md) |
| X (Twitter) | Your keys, Hand-off | Yes | 280 weighted (links = 23), threads | 4 images or 1 video | 100/15 min, 10000/day, 500/month | - | [x.md](platforms/x.md) |
| YouTube | Your keys, Hand-off | Yes | 5000 bytes | 1 video (required) | 100/day | Yes | [youtube.md](platforms/youtube.md) |
| YouTube Posts | Hand-off | Yes | No limit | 10 images | - | - | [youtube_posts.md](platforms/youtube_posts.md) |

## Cost and account notes

### BitChute

- **Account:** A BitChute account with a channel. NEFORUM never signs in to BitChute; you upload on bitchute.com.
- **Cost and limits:** Free. BitChute uploads only through its website, so NEFORUM prepares the upload and you publish it there.

### Bluesky

- **Account:** Any free Bluesky account, including ones on a self-hosted AT Protocol server. You only need to create an app password in Bluesky settings; no developer account or app review.
- **Cost and limits:** Free with no paid tiers. Bluesky only caps how fast you post (about 1,600 posts an hour) and how many videos you upload per day.

### DEV Community

- **Account:** Any DEV (or other Forem) account. You create a personal API key in your settings; no developer registration or review.
- **Cost and limits:** Free. DEV allows about 10 new articles per 30 seconds (brand-new accounts only about one per 5 minutes) and one write request per second.

### Discord

- **Account:** You need the "Manage Webhooks" permission in the Discord server. One webhook posts into one channel; no bot or developer account is needed.
- **Cost and limits:** Free. Discord limits how fast a webhook may post (it tells NEFORUM how long to wait) and how big files may be (20 MiB each unless the server is boosted).

### Facebook

- **Account:** Automatic posting works only for Facebook Pages you manage, through a free Meta developer app you create yourself; personal profiles and groups cannot be posted to by any app. For a personal profile, use hand-off: NEFORUM copies your text and opens Facebook so you can paste and post.
- **Cost and limits:** The Graph API is free. Meta allows about 4,800 calls per day multiplied by the number of people who engaged with your Page, which is plenty for normal posting; new Pages with no engagement get much less.

### Ghost

- **Account:** A Ghost site where you are Owner or Administrator (to create a custom integration). Self-hosted Ghost works on any setup; on Ghost(Pro) custom integrations are included in the Publisher, Business and Custom plans, not in Starter.
- **Cost and limits:** Free on self-hosted Ghost. On Ghost(Pro) the Admin API needs the Publisher plan or higher (not Starter). Ghost does not publish an API quota.

### Google Business Profile

- **Account:** You must be an owner or manager of a verified Google Business Profile. NEFORUM never signs in to Google; you add the update on business.google.com or in Google Maps.
- **Cost and limits:** Free. Google's Business Profile API only works after Google approves a separate access request for your own Google Cloud project, so NEFORUM uses hand-off: it copies your text and opens Google.

### Hashnode

- **Account:** A Hashnode account with a blog. API posting only works when that blog is on the paid Hashnode Pro plan; the hand-off option works on any plan.
- **Cost and limits:** Since May 2026 Hashnode only answers API calls for blogs on Hashnode Pro (paid per seat). Within Pro the limits are generous (500 write calls a minute).

### Instagram

- **Account:** Hand-off works with any Instagram account, including personal ones: NEFORUM copies the caption and hands the photo or video to the Instagram app. Automatic posting needs a professional (Business or Creator) account and your own free Meta developer app; personal accounts cannot use the API.
- **Cost and limits:** The Instagram API is free. Meta's docs give each account 100 API posts per rolling 24 hours in one place and 50 in two others; NEFORUM counts up to 100 and treats Instagram's own limit error as a quota problem. Photos must be put on a public media host you configure because Instagram downloads them from a link.

### Lemmy

- **Account:** Any ordinary account on a Lemmy instance (lemmy.world, lemmy.ml, ...). No developer account, app or review is needed; you sign in with your username and password.
- **Cost and limits:** Free. By default an instance allows about 6 posts every 10 minutes and 6 image uploads an hour; each instance sets its own limits and image size.

### LinkedIn

- **Account:** A normal LinkedIn profile is enough. For automatic posting you create a free LinkedIn developer app, which must be linked to a LinkedIn company Page you administer (creating a Page is free).
- **Cost and limits:** Free. LinkedIn allows about 150 API calls per member per day, and you must reconnect every 60 days because LinkedIn sign-ins expire and cannot be renewed automatically.

### Mastodon

- **Account:** Any normal account on a Mastodon-compatible server (Mastodon, Pleroma, Akkoma, GoToSocial, Friendica, Pixelfed, Mitra). You only type your server address and approve NEFORUM in the browser.
- **Cost and limits:** Free on every server, with no developer account or app review. Mastodon allows about 300 API calls per 5 minutes, 30 media uploads per 30 minutes and 25 scheduled posts per day.

### Matrix

- **Account:** Any account on any Matrix homeserver (matrix.org or your own) that may post in the room. The room must not be end-to-end encrypted.
- **Cost and limits:** Free and open. Your homeserver decides how fast you may post and how large files may be.

### Micropub (IndieWeb / Micro.blog)

- **Account:** Your own website or Micro.blog blog with Micropub and IndieAuth turned on. No developer account or app registration is needed.
- **Cost and limits:** The protocol is free and has no published rate limits. Micro.blog needs a paid hosted plan for a hosted blog; your own site costs whatever your hosting costs.

### Misskey

- **Account:** Any ordinary account on a Misskey, Sharkey, CherryPick, Firefish or Iceshrimp-JS server. No developer account or app review is needed.
- **Cost and limits:** Free. Your server allows about 300 notes and 120 file uploads per hour, and sets its own file-size and storage limits.

### Nostr

- **Account:** Just a Nostr key pair (your nsec private key). No email, phone number, sign-up or app review is needed, and any Nostr app can create a key for you.
- **Cost and limits:** Free with no quota. Individual relays may rate-limit or charge; free media uploads to nostr.build are limited to 20 MB per file.

### Odysee

- **Account:** Automatic: the LBRY desktop app on this computer, signed in with your Odysee account, and a little LBC for the deposit. Hand-off: any Odysee account.
- **Cost and limits:** Free apart from a tiny LBC deposit per upload (0.001 LBC by default), which you get back if you remove the video. No developer keys.

### Pinterest

- **Account:** Automatic posting needs a Pinterest business account (converting a personal account is free and keeps your profile) and your own Pinterest developer app, which Pinterest must approve before it works. Until Pinterest also grants the app Standard access, Pins it creates are only visible to you.
- **Cost and limits:** Free. With Trial access Pinterest allows about 300 new Pins and 1000 API calls per day, and the Pins stay private to you; Standard access (after a video review by Pinterest) makes them public.

### Reddit

- **Account:** Any Reddit account. Automatic posting needs your own Reddit "installed app" (client ID). Since November 2025 Reddit approves new API apps by hand, so if you do not have one yet use hand-off.
- **Cost and limits:** The Reddit API is free for personal, non-commercial use, up to 100 requests per minute per app. Hand-off is free because you press Post yourself.

### Rumble

- **Account:** Any Rumble account. NEFORUM never signs in to Rumble; you upload on rumble.com.
- **Cost and limits:** Free. Rumble has no upload API for personal accounts, so NEFORUM prepares the upload and you publish it on rumble.com.

### Snapchat

- **Account:** Any Snapchat account and the Snapchat app on your phone. NEFORUM never signs in to Snapchat; you post from the Snapchat app.
- **Cost and limits:** Free. Snapchat's posting API is only for approved partners posting for brands and creators, so NEFORUM hands your photo or video to the Snapchat app and you tap Send.

### Substack Notes

- **Account:** Any Substack account (you do not need your own publication). NEFORUM never signs in to Substack; you post from substack.com or the Substack app.
- **Cost and limits:** Free. Substack has no API for posting Notes, so NEFORUM copies your text and opens Substack; you paste it and tap Post.

### Telegram

- **Account:** Any Telegram account can create a bot with @BotFather in a minute. The bot then has to be an administrator (with "Post Messages") of your channel, or a member of your group.
- **Cost and limits:** Free, with no app review. Telegram only slows down bots that send many messages per minute.

### Threads

- **Account:** Any Threads profile works. For automatic posting you create your own free Meta developer app with the "Access the Threads API" use case and add your profile as its Threads Tester, so no App Review is needed.
- **Cost and limits:** The Threads API is free. Each profile can publish up to 250 posts per day through it; images and videos must first be uploaded to a public media host you configure.

### TikTok

- **Account:** Hand-off works with any TikTok account: NEFORUM opens TikTok with your video and copies the caption. "Your own API keys" needs your own TikTok developer app, and UNTIL TIKTOK AUDITS THAT APP EVERY POST IS PRIVATE ("Only me") and your TikTok account itself must be set to private.
- **Cost and limits:** Free: TikTok sells no API plan. But an unaudited app (which is what you get) can only post PRIVATE videos that nobody else sees, and TikTok allows roughly 15 API posts per account per day.

### Tumblr

- **Account:** Any normal Tumblr account works. For automatic posting you register your own free Tumblr app at tumblr.com/oauth/apps, which takes a minute and needs no review.
- **Cost and limits:** Free. Tumblr allows 250 posts a day per user, and your own app gets 1,000 API calls an hour and 5,000 a day, far more than NEFORUM needs.

### WhatsApp

- **Account:** Any WhatsApp account with the WhatsApp app on your phone, or WhatsApp Web / WhatsApp Desktop on a computer. NEFORUM never signs in to WhatsApp.
- **Cost and limits:** Free. WhatsApp has no API for Status or Channels, and its paid Business Platform only sends messages to customers, so NEFORUM opens WhatsApp for you and you tap Send.

### WordPress

- **Account:** A self-hosted WordPress 5.6 or newer site served over https, and a user with at least the Author role (Contributors can only submit drafts for review). No developer account or app review is needed.
- **Cost and limits:** Free. WordPress has no API quota of its own; your web host may limit uploads or requests.

### Write.as / WriteFreely

- **Account:** A Write.as account or an account on any WriteFreely server; Write.as also allows anonymous posts. No developer account or app review is needed.
- **Cost and limits:** Free. Free Write.as accounts have a daily limit on new posts that grows with account age, and fast bursts are refused for a while; paid Write.as plans are exempt. Self-hosted WriteFreely sets its own rules.

### X (Twitter)

- **Account:** Any X account works. Automatic posting needs your own X developer app (created at console.x.com, no review) with credits on it; hand-off needs only the X app or website.
- **Cost and limits:** Since February 2026 new X developer accounts are pay-per-use with no free tier: each post costs about $0.015, or $0.20 if it contains a link, paid from credits you buy at console.x.com. Hand-off is free because you press Post yourself.

### YouTube

- **Account:** A Google account with a YouTube channel. "Your own API keys" also needs a free Google Cloud project with an OAuth client that you create yourself (about 10 minutes); hand-off only needs the YouTube app or website.
- **Cost and limits:** Free: Google gives every project 100 uploads a day and sells no paid plan. Uploads from a project Google has not audited (yours) may be locked to PRIVATE by YouTube; if that happens, use hand-off for public videos.

### YouTube Posts

- **Account:** Any channel with advanced features turned on (YouTube Studio > Settings > Channel > Feature eligibility) that is not set as "Made for Kids". There is no subscriber minimum. NEFORUM never signs in to YouTube; you post on youtube.com or in the YouTube app.
- **Cost and limits:** Free. YouTube's API can upload videos but cannot create posts, so NEFORUM uses hand-off: it copies your text and opens YouTube, where you choose Create > Create post. For videos, connect "YouTube".


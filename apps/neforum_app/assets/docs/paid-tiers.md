# Paid plans and account limits

Some networks let a paying or verified account post more: longer posts, longer videos. Since 1.4.4 NEFORUM keeps the plan of **each account** and uses that account's limits everywhere: the character counter, the rules check, splitting long text into a thread (a long post that fits one post is sent as one post), the video length and size check, and the preview.

## Steps

1. Connect the account as usual. Where the network says which plan an account has (X with your own keys, YouTube with your own keys), NEFORUM reads it when you connect. Otherwise the connect form asks: a **Parler Premium** switch, or an **X plan** list for X by hand-off.
2. Open **Accounts**. The account card shows the plan, who set it ("Read from X on 16 Nov 2026" or "Chosen by you") and what it changes.
3. To change it, tap the pencil beside the plan and pick another one. For X with your own keys, **Ask X again** reads it from X once more (one profile read on your X developer account).
4. After you buy or cancel a plan, or verify a YouTube channel, change the plan on the card or reconnect the account so NEFORUM reads it again.

## Per network

Status as of 16 November 2026. "API" is what NEFORUM uses when it posts for you; "app" is what you get by hand-off, where you post in the network's own app or site.

| Network | Plan | What changes in NEFORUM | API or app | How NEFORUM knows | Source |
|---|---|---|---|---|---|
| X (your own keys) | X Premium Basic, Premium, Premium+, The X Subscription (Plus, Premium, Super, Ultra), Verified Organization | Posts up to **25,000** characters instead of 280 (still weighted: emoji and CJK count 2, links 23). Videos up to **125 minutes and 16 GB** instead of 20 minutes and 8 GB. | API: `POST /2/tweets` takes over 280 characters "unless the account has X Premium"; video caps follow the user's Premium or verified status, not the developer plan | **Detected** on connect from `GET /2/users/me` (`subscription_type`, `verified_type`), in the same call that reads the profile. Editable on the account card. | [Create Post](https://docs.x.com/x-api/posts/create-post), [Media limits](https://docs.x.com/x-api/media/introduction), [Get my user](https://docs.x.com/x-api/users/get-my-user), [X Premium](https://help.x.com/en/using-x/x-premium) |
| X (hand-off) | Same plans | Same limits: X says its API caps "match the X app". | App (x.com composer, X app) | **Chosen** on the connect form (X plan list) or the account card. Default: free. | Same as above |
| Parler | Parler Premium | Posts up to **2000** characters instead of 300. | App only (Parler has no posting API) | **Chosen**: the Parler Premium switch. Accounts set up with 1.4.3's switch keep it. | Read from Parler's web composer, 2026-11-13 ([parler.md](platforms/parler.md)) |
| YouTube videos (your own keys) | Verified channel (long uploads) | Videos up to **12 hours and 256 GB**; a standard channel is held to **15 minutes**. Not a paid plan: a phone-verified channel in good standing. | API: the same rule as YouTube itself | **Detected** on connect from the channel's `status.longUploadsStatus` (`allowed`, `eligible`, `disallowed`). Channels connected before 1.4.4 keep 12 hours until they reconnect. | [Channels resource](https://developers.google.com/youtube/v3/docs/channels) |
| YouTube videos (hand-off) | Verified channel | Nothing in NEFORUM: YouTube Studio says so when you upload. | App | Not tracked | Same |
| Discord | Nitro, Nitro Basic | **Nothing.** Nitro raises message length (4000) and uploads for *people*. NEFORUM posts through a webhook, which keeps 2000 characters per message; its upload limit follows the server's boost level, not anyone's Nitro. | API (webhook) | Not tracked | [Execute Webhook](https://docs.discord.com/developers/resources/webhook#execute-webhook) |
| Telegram (bot) | Telegram Premium | **Nothing.** Premium gives people 4 GB files and longer captions. A bot's limits (4096-character messages, 1024-character captions, 50 MB files) do not change. | API (Bot API) | Not tracked | [Telegram Premium](https://telegram.org/blog/700-million-and-premium), [Bot API](https://core.telegram.org/bots/api) |
| Telegram (hand-off) | Telegram Premium | Not applied yet: in the Telegram app Premium sends files up to 4 GB (2 GB without) and longer captions. NEFORUM's hand-off still uses the bot's limits. | App | Not tracked | [Telegram Premium](https://telegram.org/blog/700-million-and-premium) |
| Mastodon and compatible servers | No paid plan | Each server sets its own limits. NEFORUM already reads the server's character limit, media limits and link weight when you connect (`/api/v2/instance`). | API | Read from the server | [Mastodon instance API](https://docs.joinmastodon.org/methods/instance/) |
| Misskey and forks | No paid plan | The server's note length is read when you connect. | API | Read from the server | NEFORUM's Misskey adapter |
| Bluesky | None yet | Nothing. Bluesky has announced subscriptions but, as of November 2026, sells no plan that changes post or video limits. | API | Not tracked | Bluesky's announcements (no plan on sale) |
| LinkedIn | LinkedIn Premium | Nothing NEFORUM checks: Premium adds InMail, insights and courses, not longer posts (3000 characters) or other API limits. | API | Not tracked | Not checked against an official page for 1.4.4 |
| Reddit | Reddit Premium | Nothing: an ad-free plan with coins and avatar items, no posting limits. | API | Not tracked | Not checked against an official page for 1.4.4 |
| Tumblr | Ad-free, Tumblr Premium | Nothing: no posting limits change. | API | Not tracked | Not checked against an official page for 1.4.4 |
| Threads, Instagram, Facebook | Meta Verified | Nothing: a badge and support, not posting limits. | API | Not tracked | Not checked against an official page for 1.4.4 |
| Flickr | Flickr Pro | Already required: Flickr gives API keys to Pro members only, so every API account is Pro. | API | Not tracked | [platforms/flickr.md](platforms/flickr.md) |
| Other networks in NEFORUM | None found | No paid plan that changes a limit NEFORUM checks. | | | |

## How it works

- The plan lives in the account's settings (`subscriptionTier`, `subscriptionSource`, `subscriptionCheckedAt`), so it travels with the account through Sync and backups.
- Every network that has plans declares them once in NEFORUM's core (`PlatformAdapter.subscriptionPlansFor`); the account's limits come from `descriptorForAccount`, which the composer, the preview, the rules check, the thread splitter and the publisher all use.
- A plan NEFORUM read from the network is marked "Read from"; one you picked is "Chosen by you". Picking a plan on the card always wins until the next reconnect of an account whose plan the network reports.
- If you choose a paid plan the account does not have, the network refuses the long post or video. X then says the post is too long; set the plan back to free and post again.

## Known limitations

- X: the new "X Subscription" plans are not named in X's API docs yet. An account X reports with a plan name NEFORUM does not know gets the Premium limits; if X refuses a long post for it, choose **X free** on the card.
- X: business and government accounts (`verified_type`) count as Verified Organization with Premium limits, following X's "X Premium / verified" wording. Not verified with such an account.
- YouTube hand-off and Telegram hand-off do not track plans yet.

## Sources

- X API, Create Post: https://docs.x.com/x-api/posts/create-post
- X API, Media upload limits: https://docs.x.com/x-api/media/introduction
- X API, Get my user (`subscription_type`, `verified_type`): https://docs.x.com/x-api/users/get-my-user
- X Help Center, X Premium: https://help.x.com/en/using-x/x-premium
- YouTube Data API, Channels (`longUploadsStatus`): https://developers.google.com/youtube/v3/docs/channels
- Telegram Premium announcement: https://telegram.org/blog/700-million-and-premium
- Discord, Execute Webhook: https://docs.discord.com/developers/resources/webhook#execute-webhook

# How long each sign-in lasts

Every network NEFORUM posts to, how long its sign-in lasts, whether NEFORUM can renew it, and when you have to step in. Everything here was read from the vendor's own pages or source code on **2026-11-06**. Vendors change these rules: check the source link if a date looks wrong.

**NEFORUM renews only when a post goes out.** There is no background job. So "Renews when NEFORUM posts" also means that an account you stop posting to can run out.

Words used in the Status column:

- **VERIFIED**: the vendor's own page or source says it. Where two of its pages disagree, the row says so.
- **UNVERIFIED**: no vendor page read settles it. The row says what would. A page that says nothing about expiry is not evidence that a token never expires, so these rows say "no published limit" and not "never expires".

A date in NEFORUM reads "at the latest" where the *Known early revocation* column says something can end the sign-in first, and "about" where NEFORUM worked it out from a documented rule.

## All 50 networks

| Network | How long it lasts | Renews itself | When a person must act | Known early revocation | Source | Date read | Status |
|---|---|---|---|---|---|---|---|
| 500px | No connection: hand-off only, NEFORUM stores no key | Not applicable | Never in NEFORUM. You sign in on the site if your browser session ended | Not applicable | NEFORUM's code: `art/fivehundredpx_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Artfol | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `art/artfol_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| ArtStation | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `art/artstation_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Behance | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `art/behance_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| BitChute | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `video_sites/bitchute_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Bluesky | Session 120 minutes, its renewal key 90 days (reference server) | Yes, with the stored app password | Only when the app password is revoked or the account is taken down | Yes: revoking the app password, changing the main password | [atproto source](https://raw.githubusercontent.com/bluesky-social/atproto/main/packages/pds/src/account-manager/helpers/auth.ts) | 2026-11-06 | VERIFIED for the reference server. Other servers may differ. Settled by one live sign-in on each |
| Cara | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `art/cara_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| DEV Community | No end date: the key record has no expiry field | Not needed | When you revoke the key | Yes: revoking it in Settings > Extensions | [Forem source](https://raw.githubusercontent.com/forem/forem/main/app/models/api_secret.rb) | 2026-11-06 | VERIFIED |
| DeviantArt | Token 1 hour, its renewal key 3 months | Yes, when NEFORUM posts | About 3 months with no post | Yes: `POST /oauth2/revoke` or removing the app | [DeviantArt authentication](https://deviantart.readme.io/docs/authentication) | 2026-11-06 | UNVERIFIED whether a renewal restarts the 3 months or issues a new key: the docs' example returns the same value. Settled by comparing two refresh answers on a live account |
| Discord | No published limit on webhook addresses | Not needed | When someone deletes the webhook | Yes: anyone with Manage Webhooks in the server, or anyone holding the address | [Discord webhooks](https://docs.discord.com/developers/resources/webhook) | 2026-11-06 | UNVERIFIED. The page is silent. Settled by a Discord statement |
| Dribbble | No published limit | Not needed | When you revoke it | Yes: "can be revoked by users at any time" | [Dribbble OAuth](https://developer.dribbble.com/v2/oauth/) | 2026-11-06 | UNVERIFIED. The page is silent. Settled by a Dribbble statement |
| Facebook | Page token: no published end date. The 60-day user token behind it only serves while connecting | Not needed | After Meta ends it. An Inactive Meta app must be restored in the App Dashboard first, then reconnect | Yes: password change or logout, removed app, app Inactive after 90 days, a permission unused for 90 days | [Meta long-lived tokens](https://developers.facebook.com/docs/facebook-login/guides/access-tokens/get-long-lived/), [Meta app states](https://developers.facebook.com/documentation/development/create-an-app/app-dashboard/app-states), [Meta permissions](https://developers.facebook.com/documentation/development/permissions) | 2026-11-06 | VERIFIED. Meta's pages conflict: the Pages overview says Page tokens have an expiration time, and the tokens page warns lifetimes may change. Settled by inspecting one Page token and watching it |
| Flickr | No published limit (OAuth 1.0a) | Not needed | When you revoke it | Yes: only a forum reply says so, the formal docs are silent | [Flickr auth](https://www.flickr.com/services/api/auth.oauth.html) | 2026-11-06 | UNVERIFIED. Settled by a Flickr statement |
| Fur Affinity | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `art/furaffinity_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Ghost | Each request signs a 5-minute token. No published limit on the Admin API key itself | Not needed | When you regenerate the key | Yes: regenerating the key | [Ghost Admin API](https://docs.ghost.org/admin-api) | 2026-11-06 | UNVERIFIED that the key has no limit. Settled by Ghost's source for API keys |
| Google Business Profile | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `handoff_only/google_business_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Hashnode | No published limit | Not needed | When you revoke it. Losing Pro also stops posting | Yes: revoking the token | [Hashnode GraphQL](https://hashnode.com/blog/hashnode-gql-agent-skill) | 2026-11-06 | UNVERIFIED. Settled by Hashnode's token page in Settings > Developer |
| Inkbunny | "Several days after" last use. No date can be known | No | When a post is refused after a quiet spell | Yes: signing out, or the session timing out | [Inkbunny API wiki](https://wiki.inkbunny.net/wiki/API) | 2026-11-06 | VERIFIED |
| Instagram | 60 days. Renewal gives another 60. A pasted token's age is not known, so it shows no date until NEFORUM first renews it | Yes, when NEFORUM posts (at most once a week) | No post for about 53 to 60 days | Yes: Meta app Inactive after 90 days, a permission unused for 90 days | [Instagram refresh_access_token](https://developers.facebook.com/documentation/instagram-platform/reference/refresh_access_token), [Meta app states](https://developers.facebook.com/documentation/development/create-an-app/app-dashboard/app-states), [Meta permissions](https://developers.facebook.com/documentation/development/permissions) | 2026-11-06 | VERIFIED |
| Itaku | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `art/itaku_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Ko-fi | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `art/kofi_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Lemmy | No end date on 0.19. On 1.0 one week unless the login asks to stay, which NEFORUM 1.4 does | Not needed | After logging out or a new password. An account connected before 1.4 on a 1.0 server: at its date | Yes: logging out, a password change | [Lemmy claims.rs](https://raw.githubusercontent.com/LemmyNet/lemmy/1.0.0-beta.3/crates/api/api_utils/src/claims.rs) | 2026-11-06 | VERIFIED in source, for 0.19.21 and 1.0.0-beta.3. 0.19's `Login` struct ignores the extra field |
| LinkedIn | 60 days. Partner apps: a renewal key lasting one fixed year from the grant. An account connected before 1.4 shows no date for it: the grant date was not stored | No | Every 60 days. Reconnect before it ends: the consent screen is skipped only while the token is still valid | Yes: a different scope ends earlier tokens, the member revoking, LinkedIn at any time | [LinkedIn 3-legged OAuth](https://learn.microsoft.com/en-us/linkedin/shared/authentication/authorization-code-flow), [LinkedIn refresh tokens](https://learn.microsoft.com/en-us/linkedin/shared/authentication/programmatic-refresh-tokens) | 2026-11-06 | VERIFIED |
| Locals | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `handoff_only/locals_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Mastodon | No limit: tokens have no end and no refresh | Not needed | Only after revocation | Yes: revoking the app, a password change | [Mastodon doorkeeper.rb](https://raw.githubusercontent.com/mastodon/mastodon/main/config/initializers/doorkeeper.rb) | 2026-11-06 | VERIFIED for `main` and 5.0.0-beta.1. A date the server sends is shown whatever this says |
| Matrix | Your homeserver decides (`expires_in_ms`) | Yes, when NEFORUM posts, if the server issued a refresh token | When the server ends the session. The password is not kept | Yes: logging out, ending the device | [Matrix client-server API](https://spec.matrix.org/latest/client-server-api/) | 2026-11-06 | VERIFIED |
| Micropub (IndieWeb / Micro.blog) | Your site decides. `expires_in` is optional | Yes, when NEFORUM posts, if your site gave a refresh token | When renewal fails, or at the end with no refresh token | Yes: the revocation endpoint, you at your site | [IndieAuth spec](https://indieauth.spec.indieweb.org/) | 2026-11-06 | VERIFIED |
| Misskey | No limit: the token has no expiry column | Not needed | Only after revocation | Yes: Settings > API or Apps | [Misskey AccessToken.ts](https://raw.githubusercontent.com/misskey-dev/misskey/develop/packages/backend/src/models/AccessToken.ts) | 2026-11-06 | VERIFIED for Misskey. Forks unread. Settled by each fork's `AccessToken` entity |
| Newgrounds | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `art/newgrounds_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Nostr | None: a key signs each post, no token exists | Not needed | Never by time | None. A relay can refuse a post, which ends nothing | [NIP-01](https://raw.githubusercontent.com/nostr-protocol/nips/master/01.md) | 2026-11-06 | VERIFIED |
| Odysee | No connection: NEFORUM stores nothing, it posts through the LBRY app on this device | Not applicable | When the LBRY app is closed or signed out | Not applicable | NEFORUM's code: `video_sites/odysee_adapter.dart` | 2026-11-06 | VERIFIED no NEFORUM credential |
| Parler | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `handoff_only/parler_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Pinterest | Token 30 days, its renewal key 60 days from the last renewal | Yes, when NEFORUM posts (once the last renewal is 7 days old) | 60 days with no renewal | Yes: removing the app | [Pinterest authentication](https://developers.pinterest.com/docs/getting-started/set-up-authentication-and-authorization/) | 2026-11-06 | VERIFIED. Whether the old key still works after a renewal is not stated. Settled by refreshing a test token twice and trying the first key again |
| Pixelfed | Token 365 days, its renewal key 400 days, on defaults. Your server can change both | Yes, when NEFORUM posts (within 30 days of the token's end, taking turns with your other devices through Sync) | No post before the renewal key ends | Yes: you or your server | [Pixelfed instance.php](https://raw.githubusercontent.com/pixelfed/pixelfed/dev/config/instance.php) | 2026-11-06 | UNVERIFIED that the server sends `expires_in`. Defaults and rotation are in source. Settled by one live sign-in |
| pixiv | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `art/pixiv_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Reddit | Token 1 hour. Renewal key not documented | Yes, when NEFORUM posts | Unknown beyond revocation | Yes: you revoking it, the app losing Reddit's approval | [Reddit OAuth2 wiki, archived](https://github.com/reddit-archive/reddit/wiki/OAuth2) | 2026-11-06 | UNVERIFIED. Settled by reading r/redditdev post `olk5e6` signed in, and refreshing a test token twice |
| Rumble | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `video_sites/rumble_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Snapchat | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `handoff_only/snapchat_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Substack Notes | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `handoff_only/substack_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| Telegram | No published limit on bot tokens | Not needed | After `/token` in @BotFather | Yes: a new token from @BotFather | [Telegram bot features](https://core.telegram.org/bots/features) | 2026-11-06 | UNVERIFIED. The pages are silent. Settled by a Telegram statement |
| Threads | 60 days. Renewal gives another 60 | Yes, when NEFORUM posts (once the token is a day old) | No post for 60 days. An Inactive Meta app must be restored first | Yes: Meta app Inactive after 90 days, permission grants on private profiles | [Threads long-lived tokens](https://developers.facebook.com/documentation/threads/get-started/long-lived-tokens), [Meta app states](https://developers.facebook.com/documentation/development/create-an-app/app-dashboard/app-states) | 2026-11-06 | VERIFIED. Meta's pages conflict about private profiles. Settled by Meta's answer, or by one permission grant on a private test profile |
| TikTok | The date TikTok reports. Its pages say token 2 hours, renewal key 180 days; the same page's sample says 24 hours and 365 days | Yes, when NEFORUM posts | At the date shown | Yes: disconnecting the app, reusing a replaced key | [TikTok refresh](https://developers.tiktok.com/docs/en/oauth-refresh-a-user-access-token) | 2026-11-06 | UNVERIFIED which numbers apply. Settled by one live connect, comparing `refresh_expires_in` across two refreshes |
| Tumblr | Browser sign-in: token 42 minutes, its renewal key about 42 days | Yes, when NEFORUM posts | No post for about 42 days | Yes: removing the app | [Tumblr docs issue 134](https://github.com/tumblr/docs/issues/134) | 2026-11-06 | UNVERIFIED: 42 days comes from one reply on GitHub. That the old key dies is observed, not documented. Settled by Tumblr's answer and one live test |
| Weasyl | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `art/weasyl_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| WhatsApp | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `handoff_only/whatsapp_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |
| WordPress | No limit: an application password has no expiry field | Not needed | After revocation | Yes: on the Edit User screen | [WordPress application passwords](https://developer.wordpress.org/rest-api/reference/application-passwords/), [WordPress integration guide](https://make.wordpress.org/core/2020/11/05/application-passwords-integration-guide/) | 2026-11-06 | VERIFIED |
| Write.as / WriteFreely | Self-hosted: no limit, `validSecs` is 0 | Not needed | After logout | Yes: `DELETE /api/auth/me` | [WriteFreely database.go](https://raw.githubusercontent.com/writefreely/writefreely/develop/database.go) | 2026-11-06 | VERIFIED |
| X (Twitter) | Browser sign-in: token 2 hours, its renewal key about 6 months, single use | Yes, when NEFORUM posts | About 6 months with no post, or another device renewed first without Sync | Yes: revoking the app, X suspending the app | [X, migrating OAuth 1.0a](https://docs.x.com/fundamentals/authentication/oauth-2-0/oauth-1-0a-token-exchange) | 2026-11-06 | UNVERIFIED whether each renewal restarts the 6 months, and X's pages conflict. Settled by X's answer |
| YouTube videos | Token 1 hour. Its renewal key lasts until unused for 6 months | Yes, when NEFORUM posts | Google app in Testing: every 7 days. In production: 6 months with no post | Yes: revoking, 100 keys per account per app, the oldest dies | [Google OAuth 2.0](https://developers.google.com/identity/protocols/oauth2), [Google token types](https://docs.cloud.google.com/docs/authentication/token-types) | 2026-11-06 | VERIFIED. The 1 hour is on Google's token types page, for user access tokens; the OAuth page gives no figure. Whether a Testing grant reports its 7-day end is not known. Settled by one live connect with an app in Testing |
| YouTube Posts | No connection: hand-off only | Not applicable | Never in NEFORUM | Not applicable | NEFORUM's code: `youtube/youtube_posts_adapter.dart` | 2026-11-06 | VERIFIED. No connection that expires |

## Where one network has more than one way

| Way | How long it lasts | Renews itself | When a person must act | Known early revocation | Source | Date read | Status |
|---|---|---|---|---|---|---|---|
| X (Twitter): OAuth 1.0a keys | **X stops accepting them on 31 January 2027** | No | Before that date, reconnect by browser sign-in | Yes: revoking the app, regenerating the keys | [X, migrating OAuth 1.0a](https://docs.x.com/fundamentals/authentication/oauth-2-0/oauth-1-0a-token-exchange) | 2026-11-06 | VERIFIED. The date is on the migration guide only; another X page still says the tokens do not expire. Settled by X's answer |
| Tumblr: OAuth 1.0a keys | No published limit | Not needed | Unknown | Yes: removing the app | [Tumblr API](https://raw.githubusercontent.com/tumblr/docs/master/api.md) | 2026-11-06 | UNVERIFIED. Settled by Tumblr's answer |
| Mastodon: GoToSocial | No limit | Not needed | Only after revocation | Yes: you or your server | [GoToSocial server.go](https://codeberg.org/superseriousbusiness/gotosocial/raw/branch/main/internal/oauth/server.go) | 2026-11-06 | VERIFIED |
| Mastodon: Pleroma | Your server sets how long | Yes, when NEFORUM posts | When renewal fails | Yes: you or your server | [Pleroma cheatsheet](https://docs.pleroma.social/backend/configuration/cheatsheet/) | 2026-11-06 | UNVERIFIED default. Settled by `config/config.exs` or a live `/oauth/token` answer |
| Mastodon: Akkoma | Your server sets how long | Yes, when NEFORUM posts | When renewal fails | Yes: you or your server | [Akkoma cheatsheet](https://docs.akkoma.dev/stable/configuration/cheatsheet/) | 2026-11-06 | UNVERIFIED default. Settled the same way |
| Mastodon: Mitra | 30 days by default | No | Every 30 days on default settings | Yes: you or your server | [Mitra changelog](https://codeberg.org/silverpill/mitra/raw/branch/main/CHANGELOG.md) | 2026-11-06 | UNVERIFIED that it has no refresh grant. Settled by Mitra's `/oauth/token` source |
| Mastodon: other servers | Your server decides | Not needed | Unknown | Yes: you or your server | [Friendica Token.php](https://raw.githubusercontent.com/friendica/friendica/develop/src/Module/OAuth/Token.php) | 2026-11-06 | UNVERIFIED. Settled per server. A date the server sends is shown |
| Matrix: token pasted from Element | Unknown to NEFORUM. Possibly 5 minutes on Matrix Authentication Service | No | When it stops working | Yes: signing that Element session out | [MAS configuration](https://element-hq.github.io/matrix-authentication-service/reference/configuration.html) | 2026-11-06 | UNVERIFIED which servers keep that default. Settled by pasting one on matrix.org and retrying after 10 minutes |
| Micropub: Micro.blog app token | No published limit | Not needed | When you delete it | Yes: Account > Edit Apps | [Micro.blog API authentication](https://help.micro.blog/2018/api-authentication/) | 2026-11-06 | UNVERIFIED. Settled by Micro.blog support |
| Write.as / WriteFreely: Write.as hosted | No published limit | Not needed | After logout | Yes: `DELETE /api/auth/me` | [Write.as API](https://developers.write.as/docs/api/) | 2026-11-06 | UNVERIFIED: the hosted setting is not visible. Settled by a Write.as statement |

## What NEFORUM can read from the network itself

Most networks say how long a sign-in lasts only when it is made or renewed, so NEFORUM stores that date with the keys. A few can be asked:

- **Facebook**: `debug_token`, with your app's own token. Only its `expires_at` is used.
- **Threads**: `debug_token`, including `data_access_expires_at`.
- **LinkedIn**: `introspectToken`, with your client ID and secret.
- **Bluesky and Lemmy**: the `exp` inside the token, with no network at all.

NEFORUM asks when you connect, after a post, and when the sign-ins page opens, at most once a day per account. It never asks X in the background: X charges per request and does not say whether this read counts.

## What NEFORUM warns you about

The **Sign-ins** page in Accounts lists every connected account under three headings: **You must reconnect**, **Renews when NEFORUM posts** and **No end date known**. Each date also shows on the account's closed card. Where a network can renew now, the page offers **Renew now**. Where the network or its token can report a date, **Check now** reads it.

A notification goes out at 10:00 on these days before the date, and when the date comes:

| Case | Days before |
|---|---|
| You must reconnect | 14, 7, 3, 1 |
| Renews when NEFORUM posts | 7, 1 |
| A date the vendor announced (X keys) | 60, 30, 14, 7, 3, 1 |

- Only days still ahead when NEFORUM first learns the date count, and each one fires once on each device. A device that was off says the latest one when it next runs.
- Phones ask the system ahead of time. They keep at most 20 of these waiting, and post reminders go first when the system's room runs short. Computers check while NEFORUM runs, on its timer and when it starts.
- A banner above every section shows anything at 14 days or fewer, ended or refused. Closing it holds until the next of those days.
- A refused sign-in raises one notification until it works again, whether or not **Tell me how each post went** is on.
- Scheduling or rescheduling a post that a sign-in will not reach warns in the schedule sheet and the composer, and asks before it schedules. The queue shows the same warning for as long as it holds. A network that already holds the post still publishes it, but NEFORUM cannot change or take it back after the date, and the warning says so. A network that is only about to be asked can say no, so that warning asks first too, and if it does say no the queue says the post misses it.

## Still open

Each of these would change a row above. None can be settled from the vendor's public pages.

| Question | What would settle it |
|---|---|
| Does Pinterest's old renewal key still work after a renewal? NEFORUM keeps only the new one and takes no turns between devices | Refreshing a test token twice and trying the first key again |
| How do Meta's Threads permission rules apply to private profiles? Its pages conflict | Meta's answer, or one permission grant on a private test profile |
| Does Meta's `expires_at` of 0 mean no end? Is `data_access_expires_at` set on a Page token, and what happens at that date? | Inspecting one Page token and watching it |
| How does Meta's 90-day rule on unused permissions apply to the Page permissions it lists as exempt? | Meta's answer, or a long idle test account |
| Does a Page token end when the person loses their role on the Page? | A test with a second admin, or Meta's docs |
| Does a Google app in Testing report its 7-day end in `refresh_token_expires_in`? | One live connect with an app in Testing |
| Can a token made on X's Keys and tokens page use X's exchange? NEFORUM does not use it, and asks you to reconnect by browser instead | One test exchange on a throwaway app, or X's account team |
| Does a password change end a LinkedIn, X or TikTok sign-in? | Test accounts. The vendors' pages are silent |
| Is Instagram's `debug_token` available to Instagram Login tokens? | One call with the token as both inputs, or Meta's docs naming it |
| How long does the LBRY app's own Odysee sign-in last? | LBRY desktop source |
| Do Misskey's forks (Sharkey, CherryPick, Firefish, Iceshrimp) match Misskey? | Each fork's `AccessToken` entity |
| Are Mastodon's plans for expiring tokens in 5.0 real? | The 5.0 final release notes |

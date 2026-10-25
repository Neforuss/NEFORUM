# Mastodon setup guide

This guide connects your account on Mastodon or a compatible server, so NEFORUM posts there for you. The `mastodon` connector works with every server that speaks the Mastodon client API: **Mastodon** (including forks such as glitch-soc and Hometown), **Pleroma**, **Akkoma**, **GoToSocial**, **Friendica**, **Pixelfed**, **Mitra** and **Iceshrimp.NET**. For artwork, Pixelfed also has its own entry under Art and portfolios ([Pixelfed setup guide](pixelfed.md)), which posts only artwork posts there.

## Steps

1. In NEFORUM choose **Add account → Mastodon → Open API**.
2. Type your server address, e.g. `mastodon.social`, `fosstodon.org` or `pixelfed.social`.
   - Pasting your whole handle (`@you@mastodon.social`) also works.
3. Press **Sign in with Mastodon**. NEFORUM registers itself on your server and opens your browser on the server's approval page.
4. Sign in on your server if asked.
5. Check that the app is called **NEFORUM**, and press **Authorize**.
6. When the browser says "Signed in", close it. Your account appears in NEFORUM.

## Steps: if your server does not allow automatic app registration

Some admins block `POST /api/v1/apps`, and Pixelfed answers 404 when OAuth is switched off. In that case, create the app yourself:

1. On your server open **Preferences → Development → New application** (Mastodon).
   - Other software has a similar page, e.g. Pixelfed **Settings → Applications**.
2. Name it `NEFORUM`.
3. Set the website to `https://github.com/Neforuss/NEFORUM`.
4. Under **Redirect URI** enter the address for your device:
   - Windows and Linux: `http://127.0.0.1:52771/callback`
   - Android, iOS and macOS: `neforum://callback`
   - Paste-the-code fallback: `urn:ietf:wg:oauth:2.0:oob` (the server shows a code that you copy into NEFORUM)
   - To use one app on both desktop and phone, put both addresses on separate lines.
5. Tick the scopes `write:statuses`, `write:media` and `profile`.
   - On older Mastodon, tick `read:accounts` instead of `profile`. On other servers, tick `read` and `write`.
6. Save.
7. Copy the **Client key** and **Client secret** into the advanced fields in NEFORUM's connect form.

## Steps: hand-off

1. In NEFORUM choose **Add account → Mastodon → Hand-off**.
2. Type your server address.
3. When you publish, check the post in the composer or app NEFORUM opens, and press **Publish** yourself.

## Ways to connect

*Status as of October 2026.*

| Tier | What you need | Cost | Review | What NEFORUM can do |
|---|---|---|---|---|
| **Open API** (recommended) | A normal account on any compatible server | Free | None | Posts, threads, images, video, alt text, content warnings, visibility, language and scheduling on the server |
| **Hand-off** | Only your server address | Free | None | Opens your server's composer with the text filled in (Mastodon only), or the share sheet with your images attached. You press **Publish** yourself |

You do not need a business, creator or "professional" account, and you do not need a developer account. The API is free on every server.

## How it works

### When you connect

- NEFORUM reads the server's limits (`/api/v2/instance`, or `/api/v1/instance` on Pleroma/Akkoma) and works out which software it runs (`/.well-known/nodeinfo`).
- It registers itself on that server as an app called **NEFORUM** (`POST /api/v1/apps`). No portal visit is needed.
- It registers exactly one of the redirect addresses listed in the steps above, then opens your browser on your server's approval page.

### Permissions NEFORUM asks for

| Server | Scopes |
|---|---|
| Mastodon 4.3 and newer | `write:statuses write:media profile` |
| Mastodon before 4.3 | `read:accounts write:statuses write:media` |
| Pixelfed, GoToSocial, Pleroma, Akkoma, Friendica, Mitra, others | `read write` (Pixelfed checks the umbrella `write` scope itself) |

NEFORUM cannot read your direct messages, follow people or change your profile with the Mastodon scopes.

### Publishing

- Media are uploaded first (`POST /api/v2/media`) with your alt text. Videos are processed in the background on the server; NEFORUM waits until they are ready (up to about 3 minutes).
- Long posts can be published as a **thread**: every part is a reply to the previous one. Media goes on the first part. All parts get the same visibility and content warning.
- Visibility: *Public* → `public`, *Unlisted* → `unlisted` (quiet public), *Followers* → `private` (followers only), *Private* → `direct` (only you, unless you mention someone).
- Language: NEFORUM sends the two-letter code (`en-GB` becomes `en`).
- Each post carries an `Idempotency-Key`. If the connection drops and NEFORUM retries within an hour, Mastodon returns the post it already made instead of posting twice. The key changes when you edit the post. Posts handed to the server's scheduler get a new key every time, because Mastodon and Pleroma/Akkoma would otherwise answer a re-scheduled or "publish now" request with the copy NEFORUM had just removed.
- If a thread fails half-way, the parts already posted stay up and NEFORUM does not retry (that would post them twice). The error lists the ids of the parts that went out.

### Scheduling on the server

If you let the server hold a scheduled post, NEFORUM uploads the media, sends the post with `scheduled_at`, and your server publishes it at the time you chose, even if NEFORUM is closed. When you edit, reschedule, delete or "publish now" such a post, NEFORUM first removes the held copy (`DELETE /api/v1/scheduled_statuses/:id`; a copy that is already gone counts as removed).

| Server | Holds scheduled posts |
|---|---|
| Mastodon | Yes |
| Pleroma, Akkoma | Yes |
| Friendica | Yes |
| GoToSocial | From version 0.20; older versions refuse |
| Pixelfed, Mitra | No |
| Other or unknown software | Not used: a server that ignored the time would publish immediately |

- The time must be **at least 5 minutes in the future** (NEFORUM wants 6, to leave room for uploads and clock differences). Closer times, threads (replies need the first post to exist) and servers from the "No" rows are scheduled by NEFORUM on your device instead; the app must then be running at that time.
- Mastodon and GoToSocial allow **25 scheduled posts per day and 300 in total**.
- A scheduled post's link is not known until it is published, so NEFORUM shows it as "scheduled".

### Hand-off

- **Mastodon**: NEFORUM opens `https://your.server/share?text=...` in your browser. You must be signed in to that server in the browser. The share page can only take text, not images. Visibility is pre-selected only if it is more private than your default.
- **Phone with images**: NEFORUM opens the share sheet with your images attached and the text on the clipboard. Pick the official Mastodon app (`org.joinmastodon.android` on Android) or your usual client.
- **GoToSocial, Pixelfed, Akkoma, Friendica**: these have no share page. NEFORUM copies the text and opens your server so you can paste it.
- Content warnings cannot be prefilled. Add them with the **CW** button.

### Sign-in lifetime

Mastodon and GoToSocial sign-ins do not expire. They end only if you revoke NEFORUM under **Preferences → Account → Authorized apps**, or remove the account in NEFORUM (which revokes the token). Pleroma and Akkoma sign-ins can expire; NEFORUM renews them automatically.

Mastodon plans optional expiring tokens and removal of tokens unused for two years in a future version 5.0. Reconnecting fixes either case.

## Limits

### What NEFORUM checks before posting

NEFORUM uses **your server's own limits**, which it reads when you connect, instead of the vanilla defaults:

| Limit | Vanilla Mastodon | Other servers (typical) |
|---|---|---|
| Characters per post | 500 | GoToSocial, Akkoma, Mitra: 5000. Pixelfed: 500 caption |
| Links | count as 23 characters, whatever their length | same, where the server reports it |
| Mentions | `@user@other.server` counts as `@user` | |
| Content warning | counts toward the same character limit | Pixelfed: max 140 |
| Media per post | 4 | GoToSocial: 6 |
| Image size | 16 MB | GoToSocial: 40 MB; Pixelfed: about 15 MB |
| Video size | 99 MB, 1 video per post, no mixing with images | Pixelfed: only if the admin enabled video |
| Image pixels | 33,177,600 (e.g. 7680×4320) | Pixelfed reports 2,073,600 |
| Alt text | 1500 characters (`description_limit`) | Pixelfed: 1000 |

Server-specific rules:

- **Pixelfed** needs at least one image per post, has no "direct" visibility, and cannot hold scheduled posts.
- **Mitra** treats text as Markdown by default; NEFORUM sends `content_type=text/plain` so your text appears as typed.
- **GoToSocial** ignores the duplicate-protection header (see *Known limitations*).

Server limits are read when you connect. Reconnect the account if your admin changes them.

### Rate limits

Defaults on Mastodon (admins can change them):

- 300 API calls per account every 5 minutes, and 300 per IP address every 5 minutes. One post uses one call plus one per media file.
- 30 media uploads every 30 minutes.
- 25 scheduled posts per day, 300 pending in total.

GoToSocial limits by IP address (300 per 5 minutes across the whole API). Pixelfed allows 1000 posts per day. When a server answers "rate limited", NEFORUM waits until the time the server gives in its `X-RateLimit-Reset` header.

### Known limitations

- NEFORUM counts characters as Unicode code points. Mastodon counts user-perceived characters (grapheme clusters), so a family emoji such as 👨‍👩‍👧 counts as several characters in NEFORUM but one on Mastodon. NEFORUM errs on the safe side.
- Pixelfed and GoToSocial may count characters differently from Mastodon. Leave a few characters of margin.
- GoToSocial ignores `Idempotency-Key`, so a retry after a dropped connection can post twice.
- Polls, quote posts, audio and custom thumbnails are not supported yet.
- Akkoma's `preview` dry run, local-only posts and Friendica titles are not used.

## Troubleshooting

- **"allows only a few app registrations"**: the server may limit app registrations to 5 per 10 minutes per IP address. If you connect several accounts in a row, wait 10 minutes.
- **"invalid token"**: NEFORUM asks you to reconnect.
- **"duplicate idempotency key"** (Pixelfed, on a retry): NEFORUM reports that the post was probably already made. Check your profile.

## Sources

- https://docs.joinmastodon.org/methods/apps/
- https://docs.joinmastodon.org/methods/oauth/
- https://docs.joinmastodon.org/spec/oauth/
- https://docs.joinmastodon.org/api/oauth-scopes/
- https://docs.joinmastodon.org/methods/statuses/
- https://docs.joinmastodon.org/methods/scheduled_statuses/
- https://docs.joinmastodon.org/methods/media/
- https://docs.joinmastodon.org/entities/Instance/
- https://docs.joinmastodon.org/api/rate-limits/
- https://github.com/mastodon/mastodon/blob/main/app/validators/status_length_validator.rb
- https://github.com/mastodon/mastodon/blob/main/app/models/scheduled_status.rb
- https://github.com/mastodon/mastodon/blob/main/config/initializers/doorkeeper.rb
- https://github.com/mastodon/mastodon/blob/main/app/services/post_status_service.rb
- https://codeberg.org/superseriousbusiness/gotosocial/releases (v0.20.0: scheduled statuses)
- https://codeberg.org/superseriousbusiness/gotosocial/src/branch/main/internal/processing/status/create.go
- https://github.com/friendica/friendica/blob/develop/doc/en/spec/api/mastodon.md
- https://docs.gotosocial.org/en/latest/api/authentication/
- https://docs.gotosocial.org/en/latest/api/ratelimiting/
- https://docs.gotosocial.org/en/latest/configuration/statuses/
- https://docs.gotosocial.org/en/latest/configuration/media/
- https://docs.akkoma.dev/stable/development/API/differences_in_mastoapi_responses/
- https://docs-develop.pleroma.social/backend/development/API/differences_in_mastoapi_responses/
- https://github.com/pixelfed/pixelfed/blob/dev/app/Http/Controllers/Api/ApiV1Controller.php
- https://codeberg.org/silverpill/mitra/src/branch/main/docs/openapi.yaml
- https://github.com/mastodon/mastodon-android/blob/master/mastodon/src/main/AndroidManifest.xml

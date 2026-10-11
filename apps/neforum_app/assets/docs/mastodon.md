# Mastodon and compatible servers

NEFORUM's `mastodon` connector works with every server that speaks the Mastodon client API:
**Mastodon** (including forks such as glitch-soc and Hometown), **Pleroma**, **Akkoma**, **GoToSocial**,
**Friendica**, **Pixelfed**, **Mitra** and **Iceshrimp.NET**.

*Status as of October 2026.*

## Ways to connect

| Tier | What you need | Cost | Review | What NEFORUM can do |
|---|---|---|---|---|
| **Open API** (recommended) | A normal account on any compatible server | Free | None | Posts, threads, images, video, alt text, content warnings, visibility, language and scheduling on the server |
| **Hand-off** | Only your server address | Free | None | Opens your server's composer with the text filled in (Mastodon only), or the share sheet with your images attached. You press **Publish** yourself |

You do not need a business, creator or "professional" account, and you do not need a developer account.
The API is free on every server.

## Connecting with the Open API tier (no developer portal)

1. In NEFORUM choose **Add account → Mastodon → Open API**.
2. Type your server address, e.g. `mastodon.social`, `fosstodon.org` or `pixelfed.social`. Pasting your whole
   handle (`@you@mastodon.social`) also works.
3. Press **Connect**. NEFORUM:
   - reads the server's limits (`/api/v2/instance`, or `/api/v1/instance` on Pleroma/Akkoma) and works out which
     software it runs (`/.well-known/nodeinfo`);
   - registers itself on that server as an app called **NEFORUM** (`POST /api/v1/apps`). No portal visit needed;
   - opens your browser on your server's approval page.
4. Sign in on your server if asked, check that the app is called **NEFORUM**, and press **Authorize**.
5. The browser says "Signed in" and you can close it. Your account appears in NEFORUM.

### Permissions NEFORUM asks for

| Server | Scopes |
|---|---|
| Mastodon 4.3 and newer | `write:statuses write:media profile` |
| Mastodon before 4.3 | `read:accounts write:statuses write:media` |
| Pixelfed, GoToSocial, Pleroma, Akkoma, Friendica, Mitra, others | `read write` (Pixelfed checks the umbrella `write` scope itself) |

NEFORUM cannot read your direct messages, follow people or change your profile with the Mastodon scopes.

### Redirect addresses

NEFORUM registers exactly one of these when it creates its app on your server:

- Desktop (Windows, macOS): `http://127.0.0.1:52771/callback`
- Mobile (Android, iOS): `neforum://callback`
- Paste-the-code fallback: `urn:ietf:wg:oauth:2.0:oob` (the server shows a code that you copy into NEFORUM)

### If your server does not allow automatic app registration

Some admins block `POST /api/v1/apps`, and Pixelfed answers 404 when OAuth is switched off. In that case,
create the app yourself:

1. On your server open **Preferences → Development → New application** (Mastodon). Other software has a
   similar page, e.g. Pixelfed **Settings → Applications**.
2. Name it `NEFORUM` and set the website to `https://github.com/neforum-app/neforum`.
3. Under **Redirect URI** enter the address for your device from the list above. To use one app on both desktop
   and phone, put both on separate lines.
4. Tick the scopes `write:statuses`, `write:media` and `profile` (on older Mastodon, `read:accounts` instead of
   `profile`; on other servers `read` and `write`).
5. Save, then copy the **Client key** and **Client secret** into the advanced fields in NEFORUM's connect form.

The server may limit app registrations to 5 per 10 minutes per IP address. If you connect several accounts in a
row and see "allows only a few app registrations", wait 10 minutes.

## What NEFORUM checks before posting

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

- **Pixelfed** needs at least one image per post, has no "direct" visibility, and ignores scheduling.
- **Mitra** treats text as Markdown by default; NEFORUM sends `content_type=text/plain` so your text appears as
  typed.
- **GoToSocial** ignores the duplicate-protection header (see below).

Re-connect the account if your admin changes the server's limits.

## Publishing

- Media are uploaded first (`POST /api/v2/media`) with your alt text. Videos are processed in the background on
  the server; NEFORUM waits until they are ready (up to about 3 minutes).
- Long posts can be published as a **thread**: every part is a reply to the previous one. Media goes on the first
  part. All parts get the same visibility and content warning.
- Visibility: *Public* → `public`, *Unlisted* → `unlisted` (quiet public), *Followers* → `private`
  (followers only), *Private* → `direct` (only you, unless you mention someone).
- Language: NEFORUM sends the two-letter code (`en-GB` becomes `en`).
- Each post carries an `Idempotency-Key`. If the connection drops and NEFORUM retries within an hour, Mastodon
  returns the post it already made instead of posting twice.

### Scheduling on the server

If you let the server hold a scheduled post, NEFORUM sends `scheduled_at` and your server publishes it at the time
you chose, even if NEFORUM is closed.

- The time must be **at least 5 minutes in the future**. If you pick a time less than 5 minutes away, NEFORUM moves
  it to 5½ minutes from now. It never publishes early.
- Mastodon allows **25 scheduled posts per day and 300 in total**.
- Threads cannot be scheduled on the server, because replies need the first post to exist. NEFORUM schedules them
  itself.
- Pixelfed and Mitra cannot schedule. For those accounts, NEFORUM schedules locally (the app must be running at
  the time).
- A scheduled post's link is not known until it is published, so NEFORUM shows it as "scheduled".

## Rate limits

Defaults on Mastodon (admins can change them):

- 300 API calls per account every 5 minutes, and 300 per IP address every 5 minutes. One post uses one call plus
  one per media file.
- 30 media uploads every 30 minutes.
- 25 scheduled posts per day, 300 pending in total.

GoToSocial limits by IP address (300 per 5 minutes across the whole API). Pixelfed allows 1000 posts per day.
When a server answers "rate limited", NEFORUM waits until the time the server gives in its `X-RateLimit-Reset`
header.

## Hand-off tier

- **Mastodon**: NEFORUM opens `https://your.server/share?text=...` in your browser. You must be signed in to that
  server in the browser. The share page can only take text, not images. Visibility is pre-selected only if it is
  more private than your default.
- **Phone with images**: NEFORUM opens the share sheet with your images attached and the text on the clipboard.
  Pick the official Mastodon app (`org.joinmastodon.android` on Android) or your usual client.
- **GoToSocial, Pixelfed, Akkoma, Friendica**: these have no share page. NEFORUM copies the text and opens your
  server so you can paste it.
- Content warnings cannot be prefilled. Add them with the **CW** button.

## Sign-in lifetime

Mastodon and GoToSocial sign-ins do not expire. They end only if you revoke NEFORUM under
**Preferences → Account → Authorized apps**, or remove the account in NEFORUM (which revokes the token).
Pleroma and Akkoma sign-ins can expire; NEFORUM renews them automatically. If a server answers "invalid token",
NEFORUM asks you to reconnect.

Mastodon plans optional expiring tokens and removal of tokens unused for two years in a future version 5.0.
Reconnecting fixes either case.

## Known limitations

- NEFORUM counts characters as Unicode code points. Mastodon counts user-perceived characters (grapheme clusters),
  so a family emoji such as 👨‍👩‍👧 counts as several characters in NEFORUM but one on Mastodon. NEFORUM errs on
  the safe side.
- Pixelfed and GoToSocial may count characters differently from Mastodon. Leave a few characters of margin.
- GoToSocial ignores `Idempotency-Key`, so a retry after a dropped connection can post twice.
- Pixelfed answers "duplicate idempotency key" on a retry. NEFORUM reports that the post was probably already
  made; check your profile.
- Polls, quote posts, audio and custom thumbnails are not supported yet.
- Server limits are read when you connect. Reconnect the account if your admin changes them.
- Akkoma's `preview` dry run, local-only posts and Friendica titles are not used.

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
- https://docs.gotosocial.org/en/latest/api/authentication/
- https://docs.gotosocial.org/en/latest/api/ratelimiting/
- https://docs.gotosocial.org/en/latest/configuration/statuses/
- https://docs.gotosocial.org/en/latest/configuration/media/
- https://docs.akkoma.dev/stable/development/API/differences_in_mastoapi_responses/
- https://docs-develop.pleroma.social/backend/development/API/differences_in_mastoapi_responses/
- https://github.com/pixelfed/pixelfed/blob/dev/app/Http/Controllers/Api/ApiV1Controller.php
- https://codeberg.org/silverpill/mitra/src/branch/main/docs/openapi.yaml
- https://github.com/mastodon/mastodon-android/blob/master/mastodon/src/main/AndroidManifest.xml

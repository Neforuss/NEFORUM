# Matrix

NEFORUM posts to one **Matrix room** (on matrix.org, your own homeserver or any other) through the open Matrix Client-Server API. It posts as a normal Matrix account. A separate account just for posting is a good idea.

Status as of October 2026: Matrix is an open protocol. There is no developer portal, no app registration and no review. Cost and limits depend only on your homeserver, and matrix.org is free.

## Ways to connect

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API** | A Matrix account that may post in the room, plus its access token or password. The room must **not** be end-to-end encrypted. | Free | Set by your homeserver: Synapse allows by default about 0.2 messages per second with bursts of 10, and files up to 50 MB. NEFORUM reads the real upload limit when you connect. |

There is no hand-off option: Matrix apps have no link that fills in a message.

## Connect

1. In NEFORUM, add **Matrix**.
2. **Homeserver**: your server name, for example `matrix.org` or `example.org`. NEFORUM finds the real address through `https://<server>/.well-known/matrix/client`. You can leave it empty if your user id contains the server.
3. Sign in one of two ways:
   - **Access token (preferred).** In Element (desktop/web), open **Settings > Help & About > Advanced > Access Token**, reveal it and copy it. The token belongs to that Element session. **If you sign that session out, the token stops working**, so it's best to sign in to a separate session (or a separate posting account) just to get the token.
   - **User id + password.** Enter `@you:server` and your password. NEFORUM signs in once with `m.login.password` as a new device called **NEFORUM**, keeps only the resulting token and **never stores the password**. When you remove the account from NEFORUM, it signs that device out again.
4. **Room**: the alias (`#room:server`) or the room id (`!abc123:server`, in Element under **Room settings > Advanced**). If the account isn't in the room yet, NEFORUM joins it. That works for public rooms and rooms you've been invited to.
5. **Formatting**: `markdown` (default) sends `**bold**`, `*italic*`, `` `code` ``, `> quotes` and `[label](https://…)` links as formatted text, with your text as written as the plain-text fallback. `plain` sends plain text only.

There is no redirect URI and nothing to register.

When you connect, NEFORUM checks the token (`/account/whoami`) or signs in, resolves the alias (`/directory/room/…`), joins the room if needed, makes sure the room is not encrypted, and reads the upload limit (`/_matrix/client/v1/media/config`).

## Posting

- **Text**: no character limit, but one message must stay under about 60 KB (Matrix's event size limit is 64 KiB). Long posts are sent as **one** message, not split.
- **Media**: every file is uploaded first (`POST /_matrix/media/v3/upload`). Then NEFORUM sends the text as one message and **each file as its own message** (`m.image` / `m.video`, with size, dimensions and duration). Up to 10 files per post.
- **Mentions are switched off**: messages carry an empty `m.mentions`, so nobody is pinged by accident.
- **View post** links use `https://matrix.to/#/<room>/<event>`.
- If your server issues expiring tokens with a refresh token, NEFORUM renews them automatically (`/_matrix/client/v3/refresh`).

## Known limitations

- **Encrypted rooms are not supported.** NEFORUM doesn't implement Matrix end-to-end encryption, so it refuses encrypted rooms when you connect. Most new private rooms in Element are encrypted. Use a public room, or create an unencrypted one (turn off encryption **when you create** the room; it can't be turned off later).
- **Browser (OAuth) sign-in is not supported yet.** Homeservers that only offer the newer OAuth 2.0 login (for example servers using Matrix Authentication Service with password login turned off) reject password sign-in from apps. NEFORUM tells you so. Use an access token instead. On such servers, a token copied from Element may also expire after a short time; if posting then fails with "reconnect", that is the reason.
- **No alt text.** The image message carries the file name; Matrix has no separate image-description field that clients agree on.
- **Several messages per post.** Text and each file are separate messages, so a post with 3 images is 4 messages. A busy homeserver may rate-limit that. NEFORUM waits as long as the server asks.
- **No server-side scheduling.** Scheduled posts are sent from your device, so it must be on and online at that time.

## Sources

- Client-Server API (v1.19): https://spec.matrix.org/latest/client-server-api/
- Server discovery (`.well-known`): https://spec.matrix.org/latest/client-server-api/#server-discovery
- Login and refresh: https://spec.matrix.org/latest/client-server-api/#login
- Room aliases and joining: https://spec.matrix.org/latest/client-server-api/#room-aliases
- Sending events and transaction ids: https://spec.matrix.org/latest/client-server-api/#put_matrixclientv3roomsroomidsendeventtypetxnid
- Content repository (upload, media config): https://spec.matrix.org/latest/client-server-api/#content-repository
- Message types (`m.text`, `m.image`, `m.video`) and HTML formatting: https://spec.matrix.org/latest/client-server-api/#mroommessage-msgtypes
- Rate limiting (`M_LIMIT_EXCEEDED`, `Retry-After`): https://spec.matrix.org/latest/client-server-api/#rate-limiting
- OAuth 2.0 API (not yet supported by NEFORUM): https://spec.matrix.org/latest/client-server-api/#oauth-20-api
- matrix.to links: https://spec.matrix.org/latest/appendices/#matrixto-navigation
- Synapse configuration (default upload size and rate limits): https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html

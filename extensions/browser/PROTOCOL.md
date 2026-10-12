# NEFORUM browser bridge, protocol 1

How the NEFORUM browser extension (Chrome and Firefox) and the NEFORUM desktop app talk.
The app is the server; the extension's background script is the only client.

## Transport

- HTTP on **127.0.0.1** only, on the first free port of **52772 to 52779** (52771 is the OAuth
  loopback). The extension finds the app by calling `GET /v1/hello` on each port in turn.
- JSON bodies (UTF-8), except media bytes.
- **No CORS headers**, ever. Web pages therefore cannot read any response; the extension can,
  because its background script has host permission for `http://127.0.0.1/*`.

## Refused requests (403, body `{"error": "..."}`)

1. The `Host` header is not `127.0.0.1:<port>` or `localhost:<port>` (DNS rebinding).
2. An `Origin` header is present and does not start with `chrome-extension://`,
   `moz-extension://` or `safari-web-extension://` (requests made by web pages).
3. A path that needs a token has no valid `Authorization: Bearer <token>` (401 instead of 403).

## Endpoints

### `GET /v1/hello` (no token needed)

`200 {"app": "NEFORUM", "version": "1.0.0", "protocol": 1, "paired": true|false}`

`paired` is true only when the request carries a valid token. It lets the extension check its
token without side effects.

### `POST /v1/pair` (no token needed)

Body `{"code": "123456", "browser": "Chrome"}`. The code is the 6-digit pairing code the app
shows in **Settings > Browser extension > Pair a browser**. It is valid for 5 minutes, once,
with at most 5 wrong tries (then it is cancelled and a new one must be made).

- `200 {"token": "<43-char base64url>"}`: the app stores the token in the system keychain with
  the browser name and shows it in the paired list.
- `403 {"error": "That code is wrong or has expired. Make a new one in NEFORUM."}`

### `POST /v1/unpair` (token)

Forgets this token. `204`.

### `GET /v1/job?host=<location.host>` (token)

The hand-off waiting for this site, if any. `204` when there is none (or it has expired).
A job matches when `host`, without a leading `www.`, equals one of the job's `hosts` without
`www.`.

```json
{
  "id": "j_1f3c...",                // random, new for every "Open" in a hand-off
  "platformId": "youtube_posts",
  "platformName": "YouTube Posts",
  "url": "https://www.youtube.com/@examplechannel/posts",
  "hosts": ["www.youtube.com", "youtube.com", "m.youtube.com"],
  "text": "The post text (clipboardText of the hand-off plan; may be empty)",
  "title": "Optional title (Reddit, Pinterest, blogs) or null",
  "snippets": [{"label": "Answer 1", "text": "Yes"}],
  "media": [{"index": 0, "name": "photo.jpg", "mimeType": "image/jpeg", "size": 123456, "kind": "image"}],
  "steps": "The hand-off's numbered steps (markdown), shown in the extension's panel",
  "createdAt": "2026-10-12T10:00:00Z",
  "expiresAt": "2026-10-12T10:10:00Z"
}
```

There is at most one job at a time (the newest). It expires 10 minutes after it was made.

### `GET /v1/job/<id>/media/<index>` (token)

The file's bytes with its `Content-Type`. `404` for an unknown or expired job or index.

### `POST /v1/job/<id>/result` (token)

What the extension managed to do, so the app's hand-off sheet can say so.
Body `{"status": "filled" | "partial" | "failed", "text": true, "media": 2, "message": "..."}`.
`204`. The job stays available until it expires, so the user can fill the page in again.

## Rules for the extension

- Never press the platform's Post / Share / Publish button. Filling the composer is the job;
  the user reviews and posts.
- Never send anything from the page back to the app other than the result above.
- Keep the token in `storage.local`; forget it on `401`.

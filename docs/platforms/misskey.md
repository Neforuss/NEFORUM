# Misskey, Sharkey, CherryPick, Firefish and Iceshrimp-JS

NEFORUM posts to any server that speaks the **Misskey API**. That covers Misskey (misskey.io, misskey.design, ...), Sharkey, CherryPick, and the older Firefish and Iceshrimp-JS servers.

> **Iceshrimp.NET is different.** It does not have the Misskey API. Add it with the **Mastodon** option.

Status as of October 2026: the API is free and open on every server. There is no developer portal, no app registration and no app review. Any normal account can post.

## Ways to connect

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API** (recommended) | An account on the server. You sign in through the browser (MiAuth), or you paste an access token. | Free | About 300 notes and 120 file uploads per hour per user (upstream defaults; your server can change them). File size and Drive space are set by your server. |
| **Hand-off** | An account on the server, signed in in your browser | Free | NEFORUM opens the server's share page with your text filled in. You press **Note** yourself. Files can't be attached automatically. |

### Option A: sign in through the browser (MiAuth)

1. In NEFORUM, add **Misskey** and enter your server, for example `misskey.io`. You can also paste your handle (`@you@misskey.io`).
2. Leave **Access token** empty and press **Connect**.
3. Your server opens in the browser. Sign in if it asks. Check the permissions it lists:
   - *Compose or delete notes* (`write:notes`)
   - *Edit or delete your Drive files and folders* (`write:drive`)
   - *View your account information* (`read:account`)
4. Press **Allow**. The browser sends you back to NEFORUM:
   - on Windows and macOS this is `http://127.0.0.1:52771/callback`
   - on Android and iOS it is `neforum://callback`

   You don't register either address anywhere. Misskey accepts them without any setup.

### Option B: paste an access token

1. On your server, open **Settings > API** and press **Generate access token**.
2. Name it `NEFORUM`. Turn on **write:notes**, **write:drive** and **read:account**. Turn everything else off.
3. Create the token and copy it. It is shown only once.
4. In NEFORUM, enter your server and paste the token into **Access token**.

Tokens from either option never expire. To revoke one, go to **Settings > API** (for tokens you made) or **Settings > Apps** (for MiAuth sign-ins). After that, connect again.

## What NEFORUM does when you connect

- It reads `POST /api/meta` to get your server's real **note length limit** (`maxNoteTextLength`) and file limits. Servers differ: misskey.io allows 3000 characters, while some Sharkey servers allow 100000.
- It checks the token with `POST /api/i`. This also reads your account's role policies: maximum file size, Drive capacity, the file types you may upload, and whether you may post publicly.

## Posting

- **Text** is MFM, Misskey's Markdown-like format. `#tags` and `@user@host` mentions are linked automatically. URLs count at their full length.
- **Content warning** (`cw`): up to 100 characters.
- **Visibility**: Public → `public`, Unlisted → `home`, Followers → `followers`, Private → `specified`. A `specified` note can only be seen by you and the people you mention. Add `visibleUserIds` in the per-network options to send it to specific users. If your role can't post publicly, NEFORUM sends the note as `home`.
- **Media**: up to 16 files per note, and images and videos can be mixed. Each file is uploaded to your Drive first (`drive/files/create`). Alt text goes in the file comment (max 512 characters). The "sensitive" switch marks the uploaded files as sensitive.
- **Long posts** become a thread. Each part is a reply to the one before it. Media goes on the first part.
- **Per-network options** (`extra`): `localOnly: true` keeps the note on your server and doesn't federate it. You can also set `replyId`, `channelId`, `visibleUserIds`, `reactionAcceptance`, and `visibility` to override the mapping.

## Known limitations

- **Note length for splitting.** NEFORUM decides whether to split a post into a thread using the default limit of 3000 characters. The higher limit some servers allow is used when your post is checked, but not when it's split. So on a 100000-character Sharkey server, a 5000-character post is still sent as a thread. To send it as one note, write a per-network version of the post.
- **Characters are counted slightly high.** NEFORUM counts in UTF-16 units, so emoji count as 2 characters here and 1 on the server. You may get a warning a little before you reach the real limit.
- **No server-side scheduling.** Misskey 2025.10+ can schedule notes through its drafts API. That API needs an extra permission (`write:account`), and most servers allow only **one** pending scheduled note per user by default. NEFORUM schedules posts on your device instead.
- **Drive space.** Uploaded media stays in your Drive (100 MB by default on many servers). If the Drive is full, uploads fail with "Drive is full". Delete old files on the website to make room.
- **Your server's own rules.** Sensitive-media detection and prohibited-word lists can reject a post. NEFORUM shows the server's own message when that happens.
- **Hand-off can't attach files.** The share page can only use files that are already in your Drive. NEFORUM copies your text to the clipboard, and you attach media in the composer. There is no official Misskey app for phones. Third-party apps such as Milktea may accept shared images from the share sheet.
- **Older forks.** Firefish and Iceshrimp-JS are no longer actively developed. They keep the older API, so newer options such as `reactionAcceptance` may be ignored.

## Sources

- Access tokens: https://misskey-hub.net/en/docs/for-developers/api/token/
- MiAuth: https://misskey-hub.net/en/docs/for-developers/api/token/miauth/
- Permissions: https://misskey-hub.net/en/docs/for-developers/api/permission/
- Endpoints: https://misskey-hub.net/en/docs/for-developers/api/endpoints/
- Share form: https://misskey-hub.net/en/docs/for-users/features/share-form/
- Apps: https://misskey-hub.net/en/docs/for-users/resources/apps/
- `notes/create`: https://github.com/misskey-dev/misskey/blob/develop/packages/backend/src/server/api/endpoints/notes/create.ts
- `drive/files/create`: https://github.com/misskey-dev/misskey/blob/develop/packages/backend/src/server/api/endpoints/drive/files/create.ts
- `i`: https://github.com/misskey-dev/misskey/blob/develop/packages/backend/src/server/api/endpoints/i.ts
- Error handling and rate limits: https://github.com/misskey-dev/misskey/blob/develop/packages/backend/src/server/api/ApiCallService.ts
- Limits: https://github.com/misskey-dev/misskey/blob/develop/packages/backend/src/const.ts
- Your server's live API reference: `https://<your-server>/api-doc`

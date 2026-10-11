# Bluesky (AT Protocol)

NEFORUM posts to Bluesky through the open AT Protocol API. It is free, there is no developer
account, no app review and no business-account requirement: any ordinary Bluesky account works,
including accounts on a self-hosted AT Protocol server (PDS).

*Status checked October 2026.*

## Tiers

| Tier | What you need | Cost | Limits | Review |
|---|---|---|---|---|
| **Open API (app password)**, the default | A Bluesky account and an **app password** | Free | About 1,666 posts per hour and 11,666 per day (write limit of 5,000 / 35,000 points; each post costs 3). Video: a daily upload limit set by Bluesky | None |
| **Hand-off** | Nothing. NEFORUM opens the Bluesky composer and you tap **Post** | Free | Text only through the link; media through the phone's share sheet | None |
| *OAuth (planned)* | Sign in in the browser, no password to copy | Free | Same as app password, but you have to sign in again every 14 days | None |

### What NEFORUM can post
- Text up to **300 characters** (counted as user-visible characters, so an emoji or a flag counts as 1),
  and at most 3,000 bytes. URLs count in full.
- **Links, @mentions and #hashtags are made clickable.** Mentions are looked up to the person's
  account; a handle that does not exist stays plain text.
- **Up to 4 images** (JPEG, PNG, WebP, GIF; up to **2,000,000 bytes** each) with alt text, **or one MP4
  video** (up to 300 MB and 10 minutes). A post cannot have both.
- **A link preview card** when the post has a link and no images or video. NEFORUM reads the page's
  title, description and image itself. The image is only added if it is 1,000,000 bytes or smaller.
- **Threads**: a long post is split into a chain of replies. Images go on the first post.
- Language tag (`langs`) from the post's language.
- A content label (`graphic-media` by default, or `sexual`, `nudity` or `porn` through the
  `bluesky.selfLabel` option) when you mark a post with media as sensitive.

## Connect with an app password (step by step)

An app password is a separate password for one app. It can post for you but cannot change your
email or delete your account, and you can revoke it at any time.

1. Sign in at <https://bsky.app> (or in the Bluesky app).
2. Go to **Settings > Privacy and security > App passwords**
   (direct link: <https://bsky.app/settings/app-passwords>).
3. Tap **Add App Password**, name it `NEFORUM`, and leave **"Allow access to your direct messages"**
   **off**. NEFORUM does not need DMs.
4. Copy the password it shows (format `xxxx-xxxx-xxxx-xxxx`). Bluesky shows it only once.
5. In NEFORUM choose **Add account > Bluesky > Open API** and enter:
   - **Handle**: e.g. `alice.bsky.social` (or your custom-domain handle, or your login email).
   - **App password**: the one you just created. **Never** use your main password. NEFORUM refuses
     anything that does not look like an app password.
   - **Hosting provider**: leave `https://bsky.social` unless your account lives on your own PDS.
     Then enter that server's address, e.g. `https://pds.example.org`.

No redirect URI is involved: app passwords do not use a browser sign-in.

### What NEFORUM stores
- In the account settings (not secret): your DID (`did:plc:...`), handle, the server you signed in
  at, and your PDS address. NEFORUM reads the PDS address from your DID document, so moving to
  another PDS only needs a reconnect.
- In the secure secret store: the session tokens and the app password. The access token lasts about
  2 hours and is refreshed automatically. The refresh token lasts about 90 days. If it ever
  expires, NEFORUM signs in again with the stored app password, so you do not have to reconnect.
  If you revoke the app password, NEFORUM asks you to reconnect.
- When you remove the account, NEFORUM ends the session on the server (`deleteSession`). Revoke the
  app password on the Bluesky settings page too if you no longer need it.

## Hand-off tier
NEFORUM opens `https://bsky.app/intent/compose?text=...` with your text filled in. On phones this
opens the Bluesky app; on desktop it opens the web app. The link **cannot carry images or video**:
- On Android/iOS, NEFORUM uses the share sheet (pick **Bluesky**). The Bluesky app accepts text plus
  images or one video there.
- On desktop, attach the media in the composer yourself.
- For threads, only the first part is prefilled. The whole text is on your clipboard.

## Future tier: OAuth (not implemented yet)
Bluesky introduced AT Protocol OAuth in 2024–2025. It is the officially recommended login for apps
with an end-user sign-in, and app passwords are described as fine for bots and command-line tools.
NEFORUM will add it as an option. What we know so far:
- No registration: the app publishes a public JSON "client metadata" file, and its URL *is* the
  client id.
- Every client must use PKCE (S256), pushed authorization requests (PAR) and DPoP-bound tokens.
- A desktop app that hosts its own metadata cannot use `http://127.0.0.1` redirects. It must use a
  reverse-domain custom scheme matching the metadata host (e.g. `org.example.neforum:/callback`).
  Only a special development client (`client_id=http://localhost?...`) may redirect to
  `http://127.0.0.1/<path>`, and Bluesky's tutorials call it development-only. The NEFORUM defaults
  `http://127.0.0.1:52771/callback` and `neforum://callback` therefore do **not** fit as-is.
- Apps without a server get sessions of at most **2 weeks**. After that you sign in again, which is
  why app passwords stay the default.
- Scopes for posting: `atproto` plus `transition:generic` (still accepted in Oct 2026), or the newer
  granular scopes (`repo:app.bsky.feed.post`, `blob:image/*`, `blob:video/*`,
  `rpc:<method>?aud=*` for video uploads).

## Known limitations
- **No scheduling on Bluesky's side.** Scheduled posts are sent by NEFORUM, so the device must be on
  and online at that time.
- **No private or followers-only posts**, and **no content-warning text**. Labels apply to media only.
- Image limit is 2,000,000 bytes per image (raised from 1,000,000 in 2026; older third-party guides
  still say 1 MB). Link-card images are still limited to 1,000,000 bytes. NEFORUM does not resize
  images. A larger file is refused with a message, and a large card image is left out.
- GIFs are uploaded as images and show as still pictures.
- **Video** needs a verified email address on Bluesky-hosted accounts and counts against a daily
  limit set by Bluesky (it was 25 videos / 10 GB per day at launch; Bluesky may change it). NEFORUM
  waits up to 10 minutes for processing. Only MP4 is accepted.
- The 4-image post format is used. Bluesky's 2026 "gallery" format (more items, mixed media) is not
  used yet.
- Link cards are built from the page's OpenGraph tags. Sites that block bots or build their pages
  with JavaScript only may give no card. The post still goes out with a clickable link.
- If a thread fails halfway, the parts already posted stay up. The error message links to them.
- Follow Bluesky's Developer Guidelines: cross-posting your own posts is fine; bulk or spam
  automation is not.

## Sources
- AT Protocol OAuth spec: <https://atproto.com/specs/oauth>
- Permissions / scopes: <https://atproto.com/specs/permission>, <https://atproto.com/guides/permission-requests>
- SDK auth guidance (app passwords vs OAuth): <https://atproto.com/guides/sdk-auth>
- Rate limits: <https://github.com/bluesky-social/bsky-docs/blob/main/docs/advanced-guides/rate-limits.md>
- Posts / facets guide: <https://github.com/bluesky-social/bsky-docs/blob/main/docs/advanced-guides/posts.md>
- Compose intent links: <https://github.com/bluesky-social/bsky-docs/blob/main/docs/advanced-guides/intent-links.md>
- Video upload tutorial: <https://github.com/bluesky-social/bsky-docs/blob/main/docs/tutorials/video.mdx>
- Developer guidelines: <https://github.com/bluesky-social/bsky-docs/blob/main/docs/support/developer-guidelines.md>
- Lexicons: [feed/post](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/post.json),
  [embed/images](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/embed/images.json),
  [embed/video](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/embed/video.json),
  [embed/external](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/embed/external.json),
  [richtext/facet](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/richtext/facet.json),
  [server/createSession](https://github.com/bluesky-social/atproto/blob/main/lexicons/com/atproto/server/createSession.json),
  [repo/uploadBlob](https://github.com/bluesky-social/atproto/blob/main/lexicons/com/atproto/repo/uploadBlob.json)
- App passwords settings page: <https://bsky.app/settings/app-passwords>

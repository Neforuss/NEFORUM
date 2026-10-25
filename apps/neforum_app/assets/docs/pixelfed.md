# Pixelfed setup guide

This guide connects your Pixelfed account, so NEFORUM posts your artwork to your Pixelfed server by itself. No developer account is needed.

## Steps

1. In NEFORUM, go to **Accounts > Add > Pixelfed > Open API**.
2. Type the address of your server, for example `pixelfed.social`.
   - Your full handle (`@you@pixelfed.social`) works too.
3. Click **Connect**.
4. Sign in to your server in the browser window, if it asks.
5. Approve the app called **NEFORUM**.

## Steps: post by hand-off

1. In NEFORUM, go to **Accounts > Add > Pixelfed > Hand-off (share sheet)**.
2. Type the address of your server.
3. Click **Connect**. Nothing is signed in.
4. Publish a post with Pixelfed selected.
5. Follow the numbered steps in the hand-off window.
   - On a computer, NEFORUM opens your server's **Create New Post** page (`https://your.server/i/compose`) and puts the caption on the clipboard. Save the images with **Save media to Downloads** and add them there.
   - On a phone, NEFORUM shares the images to the app you pick.

## How it works

Pixelfed only receives posts marked as artwork, with at least one image. Pixelfed speaks the same API as Mastodon, so NEFORUM connects and posts the same way it does for Mastodon:

- **Connecting** registers NEFORUM as an app on your server (`POST /api/v1/apps`), opens your browser for you to approve it, and reads your server's own limits. NEFORUM asks for `read write`, the permission Pixelfed accepts, and uses it only to publish.
- **Return address**: `http://127.0.0.1:52771/callback` on Windows and Linux, `neforum://callback` on Android, iOS and macOS. NEFORUM registers it by itself.
- **Publishing** uploads each image with its alt text, then creates the post.

Pixelfed has one caption and no title or rating fields, so:

| NEFORUM | Pixelfed |
|---|---|
| Title | The caption's first line, followed by a blank line |
| Text | The rest of the caption |
| Tags | Hashtags at the end of the caption |
| Rating: mature or adult | The post is marked **sensitive** (NSFW), so the images are hidden behind a warning |
| Content warning | The post's content warning (Pixelfed allows 140 characters) |

Pixelfed has no fields for "Made with AI" or "Ask not to train AI".

This account type is for Pixelfed servers only. A Mastodon server (or another Mastodon-compatible one) belongs under [Mastodon](mastodon.md); NEFORUM says so when you type one here.

## Limits

- **Every post needs an image.** Pixelfed refuses posts without one.
- **Limits are per server.** NEFORUM reads them when you connect. Pixelfed's own defaults are 4 photos per post, 15,000 KB per file, JPEG, PNG or GIF, and a 500-character caption. pixelfed.social, for example, takes up to 20 files of 15,360,000 bytes (JPEG, PNG, WebP and MP4) and 2,000-character captions, with 1,000 characters of alt text.
- **Posts per day**: Pixelfed caps posts at 1,000 a day.
- **No scheduling on the server.** Pixelfed cannot hold a post until later, so NEFORUM keeps scheduled posts on your device and publishes them at the time.
- **No private (direct) posts.**
- **Server settings**: an administrator can turn off app registration, registrations are rate limited (by default 3 attempts per 30 minutes), and an account can reach its storage limit.

## Troubleshooting

- **"does not allow apps to register themselves"**: create an app on your server yourself with the scopes `read write` and the return address above, then enter its client ID and secret under the advanced fields.
- **"Account size limit reached"** (HTTP 403): your account's storage on the server is full. Delete media there or ask the administrator.
- **"runs Mastodon, not Pixelfed"**: add the account under Mastodon instead.
- **Rate limited** (HTTP 429): NEFORUM tries again later.

## Sources

- Pixelfed developer documentation: <https://developers.pixelfed.org/>
- Authentication (app registration, OAuth): <https://developers.pixelfed.org/api/authentication>
- Media upload: <https://developers.pixelfed.org/api/media>
- Statuses: <https://developers.pixelfed.org/api/statuses>
- Limits of pixelfed.social: <https://pixelfed.social/api/v1/instance>
- Software defaults and registration settings: <https://raw.githubusercontent.com/pixelfed/pixelfed/dev/config/pixelfed.php>
- Web routes (`/i/compose`): <https://raw.githubusercontent.com/pixelfed/pixelfed/dev/routes/web.php>

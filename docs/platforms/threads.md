# Threads (Meta)

NEFORUM can post to Threads in two ways:

| Tier | What you need | Cost | Limits | Automatic? |
|---|---|---|---|---|
| **Your own API keys** (default) | A free Meta developer account and your own Meta app with the "Access the Threads API" use case | Free | 250 posts per profile per 24 h (a carousel counts once), 1,000 replies per 24 h | Yes |
| **Hand-off** | Nothing | Free | None | No: NEFORUM opens the Threads composer and you tap **Post** |

Status as of October 2026:

- Any Threads profile works. Threads has no business/creator split, and since September 2025 profiles without a linked Instagram account can use the API too.
- **No app review is needed** if you only post to your own profile. An unreviewed ("development") Meta app has every feature, but only for people who hold a role on the app (admin, developer or Threads Tester). You create the app, so you are its admin.
- Meta has no paid tier and no price list for the Threads API.

## Option 1: your own Meta app (automatic posting)

### 1. Create the app

1. Sign in at <https://developers.facebook.com/apps> with the Facebook/Meta account you use for development. If asked, register as a developer (free).
2. Click **Create app**.
3. When asked for a use case, choose **Access the Threads API**. This adds the Threads API product to the app. The app type does not matter for personal use.
4. Finish the wizard. You do not need to connect a business portfolio.

### 2. Permissions

Open **Use cases → Access the Threads API → Customize → Permissions** and make sure these two are added:

- `threads_basic` (always required)
- `threads_content_publish` (lets NEFORUM publish)

NEFORUM asks for nothing else.

### 3. Redirect URL (important)

Open **Use cases → Access the Threads API → Customize → Settings**. (This is a different page from *App settings → Basic*.)

- **Redirect Callback URLs:** `https://127.0.0.1:52771/callback`
  Type it in, then **click the suggestion that appears** so the address turns into a grey "chip". If you skip this, the page does not save it and shows "Please enter an OAuth redirect URI".
- **Uninstall Callback URL:** `https://127.0.0.1:52771/callback`
- **Delete Callback URL:** `https://127.0.0.1:52771/callback`

Click **Save**. The form does not save until all three are filled in. Using the same address for all three is fine.

Why this address? Meta only accepts redirect addresses that start with `https://`. It rejects `http://127.0.0.1` (which NEFORUM's desktop sign-in normally listens on) and app links such as `neforum://callback`. Nothing actually answers at `https://127.0.0.1:52771/callback`, so after you sign in your browser shows an error page. **That is expected.** The address bar of that page holds the sign-in code, and NEFORUM asks you to paste that address back in. This works the same way on Windows, macOS, Android and iOS.

You may register any other `https://` address you control instead, for example a page on your own website. Then enter that exact address in NEFORUM's "Redirect URI you registered" field. Character for character, it must match what the dashboard shows, including any trailing `/` the dashboard added.

### 4. Copy the Threads app ID and secret

On the same **Settings** page you will find the **Threads app ID** and **Threads app secret**.
Use these, **not** the Facebook App ID shown under *App settings → Basic*. A Meta app has two ID/secret pairs, and the Facebook pair does not work for Threads.

### 5. Connect in NEFORUM

1. In NEFORUM choose **Add account → Threads → Your own API keys**.
2. Paste the Threads app ID and app secret. Leave the redirect URI as `https://127.0.0.1:52771/callback` unless you registered something else.
3. Click **Connect**. Your browser opens Threads. Sign in and allow access.
4. The browser lands on a page that does not load. Copy the **whole address** from the address bar. It looks like `https://127.0.0.1:52771/callback?code=AQB...#_`. Paste it into NEFORUM. A bare code also works.
5. Done. NEFORUM swaps the one-hour token for a 60-day token and renews it automatically while you keep using the account.

The sign-in code is valid for one hour and works only once. If something fails, start the connection again to get a fresh code.

### Posting from more than one Threads profile

Add each extra profile as a **Threads Tester** under **App roles → Roles** in the developer dashboard. The tester must then accept the invite in the Threads app (**Settings → Account → Website permissions → Invites**). Until then, the sign-in window shows an error.

### Images and videos need a media host

The Threads API has no upload endpoint. Meta downloads every image and video from a **public HTTPS address** when the post is created. Before you post media, configure a media host in NEFORUM (**Settings → Media hosting**, e.g. an S3/R2/Backblaze bucket or a WebDAV/Nextcloud share). NEFORUM:

1. uploads each file to your host,
2. hands Meta the address,
3. waits until Meta reports the media as processed (videos can take a minute or more; NEFORUM checks for up to 5 minutes),
4. publishes, and
5. deletes the files from your host again (best effort).

The host must serve the file directly. Redirects, link shorteners, "are you a bot?" pages and links that expire within minutes all make Meta's download fail. Text-only posts need no media host.

## Option 2: hand-off (no setup)

NEFORUM opens `https://www.threads.com/intent/post?text=…` with your text prefilled. This is the web composer on desktop; on phones the link opens the Threads app if it is installed. You check the post and tap **Post**. The older `threads.net/intent/post` address still redirects to `threads.com`.

- A link attachment, a topic tag and the reply setting can be prefilled.
- **Images and videos cannot be prefilled** by the web link. On a phone, NEFORUM uses the system share sheet (Threads: Android package `com.instagram.barcelona`), and your text is also put on the clipboard in case Threads drops it. On a computer, drag the files into the composer.
- For threads (several posts), only the first part is prefilled. The full text is on your clipboard, so you can paste the rest with **Add to thread**.

## What NEFORUM supports

- Text posts up to **500 characters**. Meta says emoji count as their UTF-8 byte length (a typical emoji counts as 4). NEFORUM warns when emoji push a post over the limit.
- Long texts are published as a **thread**: each part is a reply to the previous one. Media goes on the first post.
- **One image or video**, or a **carousel of 2–20** images and videos (mixed is fine).
  - Images: JPEG or PNG, up to 8 MB, 320–1440 px wide (Meta resizes others), aspect ratio up to 10:1.
  - Videos: MP4 or MOV (H.264/HEVC, AAC audio), up to 5 minutes and 1 GB, 23–60 fps, at most 1920 px wide.
- **Alt text** (up to 1,000 characters) for every image and video.
- The "sensitive" flag marks media as a spoiler.
- **Link preview:** for text-only posts, the post's link is sent as `link_attachment`. Threads allows at most 5 links per post.
- Per-post options (advanced; post overrides or account defaults):
  - `topic_tag`: one topic per post, 1–50 characters, no `.` or `&`.
  - `reply_control`: one of `everyone`, `accounts_you_follow`, `mentioned_only`, `parent_post_author_only`, `followers_only`.

## Known limitations

- **No server-side scheduling.** Scheduled posts are sent by NEFORUM at the scheduled time, so the app (or the NEFORUM CLI) has to be running then.
- **Copy-paste sign-in.** Meta only allows HTTPS redirect addresses, so NEFORUM cannot catch the sign-in redirect automatically. You paste the address once per connection, and again only if the token expires.
- **Tokens expire after 60 days without use.** NEFORUM renews the token before publishing once it is a day old. If you do not post through the account for 60 days, you have to reconnect.
- **Media needs a public host** (see above). GIFs are not supported: the API only takes GIFs as GIPHY stickers, which NEFORUM does not offer.
- **Rate limits:** 250 published posts and 1,000 replies per profile per rolling 24 hours. NEFORUM counts each part of a thread against the 250, which is conservative.
- The **hand-off** tier cannot attach media on desktop, and on phones it depends on the Threads app's share target.
- If you share Threads posts to the fediverse in the Threads app, posts published through the API are federated too.

## Sources

- Get started / create an app: <https://developers.facebook.com/docs/threads/get-started>, <https://developers.facebook.com/docs/development/create-an-app/threads-use-case>
- Access tokens and permissions (authorize URL, code exchange, `#_` suffix): <https://developers.facebook.com/docs/threads/get-started/get-access-tokens-and-permissions>
- Long-lived tokens (exchange and refresh): <https://developers.facebook.com/docs/threads/get-started/long-lived-tokens>
- Posts (limits, media, carousels, link attachments, 30 s processing guidance): <https://developers.facebook.com/docs/threads/posts>
- Publishing reference (parameters, `reply_control` values, `alt_text`, `topic_tag`): <https://developers.facebook.com/docs/threads/reference/publishing>
- Troubleshooting (container statuses and error messages, publishing limits): <https://developers.facebook.com/docs/threads/troubleshooting>
- Web intents: <https://developers.facebook.com/docs/threads/threads-web-intents>
- Changelog (API host alias, link limit, profiles without Instagram): <https://developers.facebook.com/docs/threads/changelog>
- HTTPS-only redirect URIs (Meta sample README and issue #32): <https://github.com/fbsamples/threads_api>, <https://github.com/fbsamples/threads_api/issues/32>

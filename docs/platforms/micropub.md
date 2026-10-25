# Micropub setup guide

This guide connects your own website or Micro.blog blog through **Micropub**, the W3C standard for posting to your own site, so NEFORUM posts there for you. It works with Micro.blog, WordPress with the IndieAuth and Micropub plugins, Known, and many static-site setups.

## Steps

1. In NEFORUM, add **Micropub**.
2. Enter **your site URL**, for example `alice.micro.blog` or `https://alice.example/`.
   - WordPress: first install the **IndieAuth** and **Micropub** plugins and check that your home page shows the `rel` links listed under *How it works*.
3. Leave **App token** empty and press **Connect**. Your site's sign-in page opens in the browser.
4. Approve the request. NEFORUM asks for:
   - **create** (write posts)
   - **media** (upload files)
   - **profile** (so your server may send your name and photo)
5. Wait for the browser to send you back to NEFORUM:
   - Windows and macOS: `http://127.0.0.1:52771/callback`
   - Android and iOS: `neforum://callback`

You don't register anything. On a phone, servers that check redirect addresses refuse this sign-in (see *Client ids*): sign in on a computer, or use a Micro.blog app token.

## Steps: Micro.blog app token

1. Sign in at https://micro.blog and open **Account > App tokens**.
2. Create a token named `NEFORUM`.
3. In NEFORUM, add **Micropub** and enter your blog address (`yourname.micro.blog` or your custom domain).
4. Paste the token into **App token**.

App tokens don't expire until you delete them.

## Ways to connect

As of October 2026, Micropub and IndieAuth are open standards. There is no developer portal, no app registration and no app review.

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API** (the only tier) | A site with Micropub and IndieAuth turned on, or a Micro.blog app token | Free protocol. Micro.blog needs a paid hosted plan if Micro.blog hosts your blog. Your own site costs whatever your hosting costs. | No published rate limits. File sizes are set by your site. |

If NEFORUM can't post automatically, it can still hand the post off to you. The text goes on the clipboard, and on Micro.blog the app opens. See *Hand-off* below.

**WordPress:** with the **IndieAuth** and **Micropub** plugins, use the browser sign-in above. If you'd rather use WordPress's own API, add the site with the WordPress option instead.

## How it works

### When you connect

- **Discovery.** NEFORUM reads your home page, then the IndieAuth metadata document, if there is one. On the home page it looks for:
  - `rel="indieauth-metadata"`, or the older `rel="authorization_endpoint"` and `rel="token_endpoint"`
  - `rel="micropub"`

  It checks both the HTTP `Link` header and the HTML `<link>` tags.
- **Sign-in.** It uses the IndieAuth authorization code flow with PKCE (S256), the `me` parameter and a random `state`. If your server sends an `iss` value back, NEFORUM checks it against the metadata's `issuer`.
- **Token.** It exchanges the code at your token endpoint. If the token response names a different `me`, NEFORUM checks that the new URL uses the same authorization server, or it refuses.
- **Configuration.** It calls `GET <micropub>?q=config` to find:
  - your **media endpoint**
  - your **syndication targets** (`syndicate-to`)
  - your **destinations** (Micro.blog blogs)
- **Token refresh.** If your server issues expiring tokens with a refresh token, NEFORUM renews them before posting. If it can't, you're asked to reconnect.

### Client ids

You don't register anything. IndieAuth identifies an app by a *client id* URL:

- **On a computer** NEFORUM uses the loopback client id `http://127.0.0.1:52771/`. The IndieAuth spec says servers must not fetch a loopback client id, and the redirect address is on the same host and port, so your server has nothing to check.
- **On a phone** the redirect `neforum://callback` is on a different "host" than any web client id. A server that checks redirect addresses only accepts it if the client id page lists it. NEFORUM uses `https://neforum.app/`, but as of October 2026 that page does not exist yet, so servers that check will refuse the sign-in. Sign in on a computer, or use an app token (Micro.blog).

Leave **Client ID (advanced)** empty unless you host your own client metadata page that lists NEFORUM's redirect address. Some servers refuse loopback client ids; then you need such a page or an app token.

### Posting

NEFORUM sends a form-encoded `h=entry` request. Every Micropub server must accept this format. The post uses these properties:

| Post field | Micropub property |
|---|---|
| Text | `content`. Micro.blog and most servers render Markdown. |
| Title (optional) | `name`. With a title, the post is a full article. Without one, it's a note. |
| Tags | `category[]` |
| Link | Added to the end of the text |
| Images and video | Uploaded one by one to your **media endpoint**, then sent as `photo` / `photo[]` / `video` URLs |
| Alt text | `mp-photo-alt` / `mp-photo-alt[]` (Micro.blog supports this) |

**If your site has no media endpoint,** the files go in a single `multipart/form-data` request with the post.

Your server answers with `201 Created` or `202 Accepted`. The `Location` header is the post's address, and NEFORUM links to it.

**Per-network options** (`extra`):

| Option | What it does | Micropub parameter |
|---|---|---|
| `postStatus: "draft"` or `draft: true` | Creates a draft | `post-status=draft` |
| `slug` | Sets the post's slug | `mp-slug` |
| `syndicateTo: [uid, ...]` | Cross-posts to targets from `q=config`. You can also save a default in the account settings. | `mp-syndicate-to[]` |
| `destination: uid` | Picks one blog on a multi-blog Micro.blog account | `mp-destination` |

### Hand-off

- **Micro.blog:** NEFORUM shares the post to the Micro.blog app. On Android that's `blog.micro.android`. On iOS it uses `microblog://post?text=...`. The text is also on the clipboard. Attach photos in the app.
- **Other sites:** NEFORUM copies the text and opens your home page. You start a post in your own editor.

## Limits

- **Alt text.** In form-encoded and multipart requests, the Micropub spec has no standard field for alt text. NEFORUM sends `mp-photo-alt`. Micro.blog uses it, but other servers may ignore it.
- **Micro.blog timeline.** Untitled posts longer than 300 characters are shortened in the timeline (600 if the post contains a block quote). Add a title to publish a full article.
- **No server-side scheduling.** Micropub has no standard way to schedule. NEFORUM schedules on your device.
- **No threads, content warnings or visibility.** None of these are part of core Micropub, so NEFORUM doesn't send them.
- **Images per post.** The spec sets no limit. NEFORUM sends at most 10 images and 1 video per post.
- **File types and sizes** depend on your server. Micro.blog documents JPEG uploads.
- **Discovery limits.** NEFORUM finds links with a lightweight parser. Links that JavaScript adds to the page are not seen. Relative links are resolved against the address you entered, not the final address after redirects.
- **Client id on phones.** `https://neforum.app/` does not publish NEFORUM's redirect address yet, so servers that verify redirects refuse phone sign-ins. Desktop sign-in uses the loopback client id and is not affected. Use an app token (Micro.blog) on a phone.
- **Profile.** Servers may ignore the `profile` scope. NEFORUM then names the account after your site's host.

## Sources

- Micropub specification (W3C Recommendation): https://micropub.spec.indieweb.org/
- IndieAuth specification: https://indieauth.spec.indieweb.org/
- Micropub extensions (`post-status`, `mp-slug`, `mp-destination`, ...): https://indieweb.org/Micropub-extensions
- Micro.blog posting API: https://help.micro.blog/t/posting-api/96 (formerly https://help.micro.blog/2017/api-posting/)
- Micro.blog JSON / app tokens: https://help.micro.blog/2017/api-json/
- Micro.blog for Android (share target): https://www.manton.org/2023/10/30/microblog-for-android.html

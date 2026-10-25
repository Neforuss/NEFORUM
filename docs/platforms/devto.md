# DEV Community setup guide

This guide connects **DEV** (dev.to), or another community that runs Forem, to NEFORUM with a personal API key. Afterwards NEFORUM publishes your articles there automatically.

## Steps

1. Sign in at https://dev.to.
2. Open **Settings > Extensions**: https://dev.to/settings/extensions
3. Under **DEV Community API Keys**, enter `NEFORUM` as the description.
4. Press **Generate API Key**.
5. Copy the key.
6. In NEFORUM, add **DEV Community** and paste the key.
7. Leave **Forem community** set to `https://dev.to` unless you post to another Forem community; then enter its address.
8. Press **Connect**.
9. If your posts have images, set up a media host that keeps files **permanently** under **Settings > Media hosting** (see "Images need a media host" under How it works).

## Steps: Hand-off without a key

1. Sign in to DEV in your browser.
2. In NEFORUM, add **DEV Community**, choose **Hand off to the app** and click **Add DEV Community**.
3. Publish the post in NEFORUM. It opens the DEV editor with your title, tags and text filled in, and copies the full Markdown to the clipboard.
4. Upload your images in the editor. They can't travel in the link.
5. Check the preview.
6. Press **Publish**.

## How it works

NEFORUM publishes articles through the Forem API v1. Other communities that run Forem work the same way: enter their address when you connect.

As of October 2026, the API is free. Any DEV account can create a personal API key. There's no developer registration and no app review.

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API** (recommended) | A DEV account and a personal API key | Free | About 10 new articles per 30 seconds and 1 write request per second. If you go over, DEV returns HTTP 429 with `Retry-After`. |
| **Hand-off** | A DEV account, signed in in your browser | Free | NEFORUM opens the DEV editor with your title, tags and text filled in. You press **Publish** yourself. |

There's no redirect address, OAuth app or browser sign-in. The key doesn't expire. To revoke it, return to the same settings page.

When you connect, NEFORUM checks the key with `GET /api/users/me`. It sends the `api-key` header and `Accept: application/vnd.forem.api-v1+json`.

### Images need a media host

**The DEV API cannot upload files.** It only accepts image *links*. So NEFORUM first puts your images on the **media host** you set up under **Settings > Media hosting**:

- The first image becomes the cover (`main_image`).
- The other images are added at the end of the article as `![alt](url)`.

Choose a host that keeps files **permanently**, such as your own S3 or R2 bucket. A temporary host like litterbox deletes files after a while, and the images then disappear from your article. If you have no media host, posts with images fail with a clear message.

### Hand-off

NEFORUM opens `https://dev.to/new?prefill=...`. The link carries your article as Markdown, with front matter at the top (`title`, `published: true`, `tags`, and optionally `canonical_url` and `cover_image`). You must be signed in. The full Markdown is also copied to the clipboard.

## What gets posted

NEFORUM sends `POST /api/articles` with `{"article": {...}}`:

| NEFORUM | DEV field | Notes |
|---|---|---|
| Title (**required**) | `title` | 128 characters at most. If there's no title, NEFORUM uses the first line of your text. |
| Text | `body_markdown` | Markdown, up to 800 KB. A link you attach is added to the end. |
| Tags | `tags` | At most **4**, each at most **30** characters. They're lower-cased, and anything except letters and digits is removed: `Web-Dev` becomes `webdev`. Extra tags and tags that are still longer than 30 characters are dropped (DEV would refuse the whole article). |
| Images | `main_image` and inline images | See "Images need a media host" above. |

By default, `published` is set to `true`. Set `draft: true` to save the article as a draft instead.

**Per-network options** (`extra`):

| Option | DEV field |
|---|---|
| `canonicalUrl` | `canonical_url`. Use it when the article first appeared on your own blog. |
| `description` | `description` |
| `series` | `series` |
| `organizationId` | `organization_id` |
| `mainImage` | `main_image`, as an image URL you already host |
| `coverFromFirstImage: false` | Embeds every image in the article instead of using the first as the cover |

## Limits

- **No image upload.** Images need a media host, or you add them in the hand-off editor.
- **No scheduling.** The API v1 reference documents no scheduling field. (Forem's source code accepts a future `published_at`, but it is undocumented, so NEFORUM does not rely on it.) NEFORUM schedules on your device.
- **New accounts.** Forem limits accounts that are only a few days old to about one new article per 5 minutes; DEV then answers HTTP 429 with `Retry-After: 300`.
- **Duplicate titles.** DEV refuses a new article with the same title as one you posted in the last five minutes. A `canonical_url` that another published article already uses is also refused. NEFORUM shows DEV's own message.
- **Rate limits.** The 10-per-30-seconds figure comes from DEV's published guidance. Forem's code confirms the limiter but sets the exact number in each community's settings. Other Forem communities may use different limits.
- **The DEV mobile app** has no documented share target. Hand-off uses the web editor on every device.

## Sources

- Forem API v1 reference: https://developers.forem.com/api/v1
- Article API controller (tags array, 201 + Location, 422 `{error, status}`): https://github.com/forem/forem/blob/main/app/controllers/concerns/api/articles_controller.rb
- Article validations (title ≤ 128, body ≤ 800 KB, max 4 tags, duplicate-title rule): https://github.com/forem/forem/blob/main/app/models/article.rb
- Rate limiting (write throttle 1/s, Retry-After): https://github.com/forem/forem/blob/main/config/initializers/rack_attack.rb and https://github.com/forem/forem/blob/main/app/services/rate_limit_checker.rb (defaults in https://github.com/forem/forem/blob/main/app/models/settings/rate_limit.rb)
- Tag rules (letters and digits, 30 characters): https://github.com/forem/forem/blob/main/app/models/tag.rb
- Share-to-DEV prefill link: https://dev.to/share-to-dev-button
- Editor guide (front matter): https://dev.to/p/editor_guide

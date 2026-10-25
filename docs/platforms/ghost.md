# Ghost setup guide

This guide connects a **Ghost** site to NEFORUM with the Admin API key of a *custom integration* that you create on your own site. Afterwards NEFORUM publishes your posts there automatically; Ghost(Pro) Starter sites, which can't create the key, use the hand-off steps.

## Steps

1. Open your Ghost admin: `https://your-site/ghost/`.
2. Go to **Settings > Advanced > Integrations**.
   - In older versions this is **Settings > Integrations**.
3. Press **Add custom integration**.
4. Name it `NEFORUM` and press **Create**.
5. Copy the **API URL** from the integration page, for example `https://your-site.ghost.io`.
   - This can differ from your public address.
6. Copy the **Admin API key**: a long value with a colon in the middle.
   - Don't use the *Content API key*. That key is read-only.
7. In NEFORUM, add **Ghost** and paste the **API URL** and the **Admin API key**.
8. Choose **Publish as**: `published` or `draft`.
9. Press **Connect**.

## Steps: Hand-off without an integration

1. In NEFORUM, add **Ghost** and choose **Hand off to the app**.
2. Enter your **Site address**: the address you use to open Ghost admin, without `/ghost/`.
3. Click **Add Ghost**.
4. Publish the post in NEFORUM. It copies the post text to the clipboard and opens `https://your-site/ghost/#/editor/post`.
5. Paste the text.
6. Type the title and add the tags NEFORUM shows you.
7. Press **Publish**.

## How it works

Status as of October 2026:

- **Self-hosted Ghost**: the Admin API is free and unrestricted.
- **Ghost(Pro)**: custom integrations and the Admin API are included in the **Publisher**, **Business** and **Custom** plans (plan comparison on ghost.org/pricing, checked 2026-10-11). **Starter** sites can't create an Admin API key. Use **Hand-off** there.
- You don't need a developer account, app registration or app review.

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API** (recommended) | Owner or Administrator access to a Ghost site that allows custom integrations | Free when self-hosted. Ghost(Pro) Publisher or higher. | Ghost doesn't publish an API quota. Upload size depends on your Ghost setup. |
| **Hand-off** | Any Ghost site you can sign in to | Free | NEFORUM copies the text to the clipboard and opens the editor. You paste it and press **Publish**. |

You don't register any redirect address. Ghost has no browser sign-in for integrations.

To revoke access, delete the integration or press **Regenerate** on its Admin API key. Keep the key private: it can change everything on your site.

Ghost's editor can't be filled in from a link, and Ghost has no mobile app that receives shared posts. That is why hand-off copies the text and tells you the title and tags.

### How NEFORUM signs requests

The Admin API key is never sent as is. For each request NEFORUM creates a short-lived token (a JWT):

- header `{"alg": "HS256", "kid": "<key id>", "typ": "JWT"}`
- payload `{"iat": <now>, "exp": <now + 5 minutes>, "aud": "/admin/"}`
- signed with HMAC-SHA256 using the **hex-decoded** secret half of the key

The token is sent as `Authorization: Ghost <token>`, together with `Accept-Version: v5.0`. Because the token is made fresh every time, nothing ever expires or needs refreshing. Your device's clock must be correct, though. A clock that's more than a few minutes off makes Ghost reject the token with "HTTP 401".

When you connect, NEFORUM reads `GET /ghost/api/admin/site/` to get the site title and public address. It then checks the key with `GET /ghost/api/admin/posts/?limit=1`.

## What gets posted

- **Title** is required, up to 255 characters. If you leave it empty, NEFORUM uses the first line of the post.
- **Text** becomes simple HTML and is sent with `POST /ghost/api/admin/posts/?source=html`. A blank line starts a new paragraph and `https://` links become clickable. Ghost turns the HTML into normal editor cards. To send your own HTML, set the per-network option `html: true`. Add `ghostHtmlCard: true` to keep it exactly as written inside a single HTML card. Ghost's HTML conversion is lossy otherwise.
- **Tags** go into the Ghost tags field as `[{"name": "..."}]`. Ghost creates any tag that doesn't exist yet.
- **Images**: each image is uploaded with `POST /ghost/api/admin/images/upload/` (multipart `file`, `purpose=image`). The **first image becomes the feature image**, and its alt text becomes `feature_image_alt`. The other images are placed in the post. Set `featuredImage: false` to put every image in the post instead. Accepted types are JPEG, PNG, GIF, WebP and SVG.
- **Videos aren't uploaded.** Add videos in the Ghost editor.
- **Status**: `published` or `draft`, as set for the account. You can override it per post with the option `status` (`published`, `draft` or `scheduled`).
- **Scheduling**: if you let Ghost hold the schedule, NEFORUM sends `status: scheduled` and `published_at` (UTC). When Ghost answers `status: scheduled`, the post is shown as held by Ghost, and Ghost publishes it at that time, even when your device is off.
  - Only posts that Ghost will publish can be held. With **Publish as** `draft`, NEFORUM keeps the schedule on your device instead.
  - If Ghost refuses the schedule (for example a time that is too close), NEFORUM also keeps the schedule on your device.
  - When you edit, reschedule, delete or "publish now" a held post, NEFORUM deletes the scheduled copy with `DELETE /ghost/api/admin/posts/<id>/` (Ghost answers 204). If the copy is already gone (404), that counts as done.
- **Visibility**: Public and Unlisted are sent as `public`, and Followers and Private as `members`. The option `ghostVisibility` can set `public`, `members`, `paid` or `tiers` directly.
- **Other options**: `excerpt` (sent as `custom_excerpt`), `canonicalUrl` (sent as `canonical_url`, useful when the post first appeared elsewhere) and `slug`.
- **Newsletters**: NEFORUM never asks Ghost to email a post. Posts are published on the site only.

## Limits

- **Ghost(Pro) Starter** has no Admin API. Use Hand-off.
- **No video, audio or file uploads.** Ghost has endpoints for these, but they aren't documented in the official API pages, so NEFORUM doesn't use them.
- **Device clock.** The signed token is valid for at most 5 minutes, so a wrong clock causes "HTTP 401".
- **No threads, no content warnings.** Blog posts are single posts.
- **Unlisted** posts don't exist in Ghost. They are published as public, with a warning.
- **Text is converted with simple rules, not full Markdown.** Use `html: true` for full control.

## Sources

- https://docs.ghost.org/admin-api/
- https://docs.ghost.org/admin-api/posts/overview
- https://docs.ghost.org/admin-api/posts/creating-a-post
- https://docs.ghost.org/admin-api/posts/scheduling-a-post
- https://docs.ghost.org/admin-api/posts/deleting-a-post
- https://docs.ghost.org/admin-api/images/uploading-an-image
- https://docs.ghost.org/content-api/errors
- https://ghost.org/integrations/custom-integrations/
- https://ghost.org/pricing/

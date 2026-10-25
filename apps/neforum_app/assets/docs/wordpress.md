# WordPress setup guide

This guide connects a **self-hosted WordPress** site (WordPress.org software, version 5.6 or newer), so NEFORUM publishes there through the built-in REST API. NEFORUM signs in with an **application password**, a separate password that only apps can use and that you can revoke at any time.

## Steps

1. Sign in to your WordPress dashboard (`https://your-site/wp-admin/`).
2. Open **Users > Profile**.
3. Scroll down to **Application Passwords**.
4. Type `NEFORUM` as the name and press **Add New Application Password**.
5. Copy the password WordPress shows. It is shown only once. Spaces don't matter.
6. In NEFORUM, add **WordPress** and enter:
   - **Site address**: for example `https://example.com`. If WordPress is in a folder, include the folder, for example `https://example.com/blog`.
   - **WordPress username**: the name you log in with, not your display name.
   - **Application password**: the password from step 5.
7. Press the connect button.

## Steps: approve NEFORUM in the browser instead

1. In NEFORUM, add **WordPress** and enter only the **Site address**. Leave the password empty.
2. Press the connect button. NEFORUM opens your site's **Authorize application** page (`/wp-admin/authorize-application.php`).
3. Sign in if it asks.
4. Press **Yes, I approve of this connection**. WordPress sends you back to `neforum://callback`, and NEFORUM receives the password automatically.
   - WordPress only accepts `https://` or app-scheme addresses here. It refuses `http://127.0.0.1` addresses. So on desktops that can't receive `neforum://` links, NEFORUM shows you the authorize page instead. WordPress then displays the new password, and you paste it together with your username (as in *Steps*).
   - You don't need to register any redirect address.

## Steps: hand-off

1. In NEFORUM, add **WordPress** and choose **Hand-off**.
2. Enter your site address. For WordPress.com, leave it empty.
3. Sign in to your site in your browser.
4. When you publish, check the title and text in the editor NEFORUM opens, and add images yourself.
5. Press **Publish**.

## Ways to connect

Status as of October 2026: the WordPress REST API and Application Passwords are part of WordPress core and free. There is no developer portal, no app registration and no app review. Any user with the **Author** role or higher can publish. **Contributors** can only submit posts for review.

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API** (recommended) | A self-hosted WordPress 5.6+ site on **https://**, and a WordPress user with the Author, Editor or Administrator role | Free | WordPress has no API quota. Your web host may limit request rates and upload sizes (PHP `upload_max_filesize`). |
| **Hand-off** | A WordPress site (self-hosted or WordPress.com) that you are signed in to in your browser | Free | NEFORUM opens the editor with the title and text filled in. You add images and press **Publish** yourself. |

To revoke access, go to **Users > Profile > Application Passwords** and press **Revoke** next to `NEFORUM`. Removing the account in NEFORUM doesn't revoke the password for you.

## How it works

### When you connect

- NEFORUM looks for the REST API at `https://your-site/wp-json/`. If your site uses "Plain" permalinks, it uses `https://your-site/?rest_route=/` instead. The address that works is saved with the account.
- If the REST index reports a different site address (`home`), for example because `example.com` redirects to `www.example.com`, NEFORUM looks up the API again at that address and saves that one instead. Publishing through a redirect doesn't work: the post would not be re-sent to the new address, and the password is not forwarded to another host.
- It checks whether the REST index advertises Application Passwords (`authentication.application-passwords`). If not, the site isn't on https, or a plugin or host has turned the feature off.
- It checks the login with `GET /wp/v2/users/me?context=edit` and reads your capabilities. These are whether you can write posts (`edit_posts`), publish (`publish_posts`) and upload files (`upload_files`).

### Posting

- **Title** is required. If you leave it empty, NEFORUM uses the first line of the post.
- **Text** becomes simple HTML. A blank line starts a new paragraph, a single line break becomes `<br>`, and `https://` links become clickable. Lines starting with `- ` become a bullet list, and a line starting with `## ` becomes a heading. To send your own HTML, set the per-network option `html: true`. WordPress shows the content as a Classic block, which you can convert to blocks later.
- **Tags** go into the WordPress tags field. NEFORUM looks up each tag by name (`GET /wp/v2/tags?search=`) and creates the ones that are missing (`POST /wp/v2/tags`; if WordPress answers `term_exists`, the existing tag's ID is used). Any user who can write posts may create tags. If a site restricts this, missing tags are skipped and the post is still published.
- **Categories**: set the per-network option `categories` to a list of names or numeric IDs, for example `["News", 4]`. Missing categories are created when your role allows it.
- **Media**: each file is uploaded with `POST /wp/v2/media`. Alt text is then saved with `POST /wp/v2/media/<id>` (`alt_text`). The **first image becomes the featured image**. All other images and videos are placed in the post below the text. Set `featuredImage: false` to place every image in the post instead. Accepted types are JPEG, PNG, GIF and WebP images, and MP4, MOV and WebM videos. Your site may allow fewer types or smaller files.
- **Status**: the account's **Publish as** setting (`publish`, `draft` or `pending`) applies to every post. You can override it per post with the option `status`. Private visibility sends `private`. If your role can't publish, NEFORUM sends `pending` (submitted for review).
- **Scheduling**: if you let WordPress hold the schedule, NEFORUM sends `status: future` with the time as `date_gmt`, in UTC, so your site's time zone setting can't shift it. When WordPress answers `status: future`, the post is shown as held by WordPress. If WordPress answers `publish` instead (the time had already passed by the server's clock), the post is simply published.
  - Only posts that WordPress will publish can be held. With **Publish as** `draft` or `pending`, private visibility, or a Contributor account, NEFORUM keeps the schedule on your device instead.
  - When you edit, reschedule, delete or "publish now" a held post, NEFORUM deletes the scheduled copy with `DELETE /wp/v2/posts/<id>?force=true` (skipping the trash). If the copy is already gone, that counts as done.
  - **WP-Cron**: WordPress publishes scheduled posts through WP-Cron, which only runs when someone visits the site. On a site with few visitors a post can go out late, and WordPress may mark it "Missed schedule". If that matters, ask your host to run `wp-cron.php` from a real cron job every few minutes (and set `DISABLE_WP_CRON`), or keep the schedule on your device.
- **Other options**: `excerpt`, `slug`.
- After publishing, NEFORUM shows the link WordPress returns. For drafts this is a preview link.

### WordPress.com

The Open API tier is for **self-hosted** WordPress only. WordPress.com sites use a different login, OAuth2 through `public-api.wordpress.com`. That login requires each app to embed a **client secret** and doesn't document PKCE. The WordPress.com `wp/v2` proxy isn't covered by WordPress.com's own OAuth documentation either. NEFORUM therefore doesn't offer automatic posting to WordPress.com yet.

For WordPress.com, use **Hand-off** and leave the site address empty. NEFORUM then opens WordPress.com's *Press This* page (`https://wordpress.com/post/?url=…&title=…&text=…&v=5`) with the title, text and link filled in.

### Hand-off

- **Self-hosted**: NEFORUM opens `https://your-site/wp-admin/post-new.php?post_title=…&content=…`. WordPress fills in the title and text as plain text.
- **WordPress.com**: NEFORUM opens the Press This page described above.
- Very long posts don't fit in a link (more than about 6000 characters). For these, only the title is filled in and the text is on your clipboard.
- **Phones**: when the post has images, NEFORUM uses the share sheet. You can then pick the WordPress or Jetpack app. Their share extensions create a new post from shared text and links. Recent versions may also accept images, but this hasn't been confirmed.

## Limits

- **https only.** WordPress turns Application Passwords off on `http://` sites. NEFORUM also refuses to send passwords over http, except to local test hosts (`localhost`, `*.test`, `*.local`).
- **Upload size** is set by your host (`upload_max_filesize`, `post_max_size`). WordPress doesn't report it to apps, so NEFORUM finds out only when an upload fails.
- **No threads, no content warnings.** Blog posts are single posts.
- **Visibility**: WordPress only has public and private posts. "Unlisted" and "Followers" are published as public, with a warning.
- **Hand-off can't attach files.** Add images in the editor yourself.
- **Text is converted with simple rules, not full Markdown.** Bold, italics and tables are not converted. Use `html: true` for full control.

## Troubleshooting

- **"HTTP 401/403" even though the password is right**: security plugins and firewalls sometimes block `/wp-json/` or remove the `Authorization` header. Allow the REST API for logged-in users in the plugin's settings, or ask your host to pass the `Authorization` header through to PHP.

## Sources

- https://developer.wordpress.org/rest-api/reference/posts/ (`date_gmt`, `status: future`, `DELETE … force`)
- https://developer.wordpress.org/rest-api/reference/media/
- https://developer.wordpress.org/rest-api/reference/users/ (`capabilities`, `context=edit`)
- https://developer.wordpress.org/rest-api/using-the-rest-api/discovery/ (`/wp-json/` and `?rest_route=`)
- https://developer.wordpress.org/plugins/cron/ (WP-Cron runs on page loads)
- https://developer.wordpress.org/rest-api/reference/application-passwords/
- https://developer.wordpress.org/rest-api/using-the-rest-api/authentication/
- https://make.wordpress.org/core/2020/11/05/application-passwords-integration-guide/
- https://developer.wordpress.org/reference/functions/get_default_post_to_edit/ (prefilled `post-new.php`)
- https://developer.wordpress.com/docs/oauth2/ (why WordPress.com isn't automatic yet)
- https://wordpress.com/support/press-this/

# EmDash setup guide

This guide connects an **EmDash** site (the open source CMS from emdashcms.com) to NEFORUM with a personal API token that you make in your own site's admin. Afterwards NEFORUM publishes your posts there automatically; roles that can't make a token use the hand-off steps.

## Steps

1. Open your EmDash admin: `https://your-site/_emdash/admin`.
2. Go to **Settings > API Tokens**.
   - Only an Administrator sees this page.
3. Press **Create token** and name it `NEFORUM`.
4. Tick **Content Read**, **Content Write** and **Media Write**.
   - Content Write also lets NEFORUM make new tags.
5. For **Expiry**, choose **No expiry**, or an end date you will remember.
6. Create the token and copy it. It starts with `ec_pat_` and is shown only once.
7. In NEFORUM, add **EmDash** and enter your **Site address**, for example `https://blog.example.com`.
8. Paste the token into **API token**.
9. Choose **Publish as**: `published` or `draft`.
10. Press **Connect**.

## Steps: Hand-off without a token

1. In NEFORUM, add **EmDash** and choose **Hand off to the app**.
2. Enter your **Site address**.
3. Click **Add EmDash**.
4. Publish the post in NEFORUM. It copies the post text to the clipboard and opens `https://your-site/_emdash/admin/content/posts/new`.
5. Type the title and paste the text.
6. Add your photos and the tags NEFORUM shows you.
7. Press **Publish**.

## How it works

Checked against EmDash 1.5 on 2026-11-13, by reading its source and posting to a local EmDash site made from the blog template.

- EmDash is free and open source (MIT). The API is part of your own site, so there is no developer account, app review or fee.
- EmDash has no Micropub endpoint, so NEFORUM talks to its own REST API under `/_emdash/api/`.
- The token is sent as `Authorization: Bearer ec_pat_...` on every request.
- When you connect, NEFORUM reads `GET /_emdash/api/health` (open to anyone) to check that the site runs EmDash. It then reads one post with `GET /_emdash/api/content/posts?limit=1` to check the token and its Content Read permission. The site's name comes from its home page. Nothing is posted while you connect.

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API** (recommended) | An Administrator account on an EmDash 1.5 site | Free | EmDash doesn't publish an API quota. Files up to 50 MB each unless your site sets another size. |
| **Hand-off** | Any EmDash account that can write posts | Free | NEFORUM copies the text and opens the editor. You paste it and press **Publish**. |

To revoke access, open **Settings > API Tokens** and revoke the `NEFORUM` token. Keep the token private: it can change the content of your site.

### Why these three permissions

- **Content Read**: to check the token when you connect, to look up your tags, and to recognise a post that an earlier try already made.
- **Content Write**: to make the post, publish it and make new tags.
- **Media Write**: to upload your photos and videos.

## What gets posted

- **Title** is required. If you leave it empty, NEFORUM uses the first line of the post.
- **Text** is written in Markdown and becomes EmDash's own rich text (Portable Text):
  - a blank line starts a new paragraph, and a single line break stays a line break;
  - `#` to `######` headings, `**bold**`, `*italic*`, `~~struck~~`, `` `code` ``;
  - `[text](https://...)` links, and bare `https://` addresses become links;
  - `-` and `1.` lists (nested by indenting), `>` quotes, fenced code blocks, `---` breaks;
  - a line that is only `![alt](https://...)` becomes a picture.
- **HTML is never run.** Tags like `<b>` are shown as text. Only `http`, `https`, `mailto` and site links (`/...`) are linked; anything else stays plain text.
- **Photos** go to the EmDash media library with their alt text (`POST /_emdash/api/media`). The **first photo is the featured image**. The others are placed after the text. Turn off **First photo as the featured image** (under **More options** in the post's **Customize** sheet) to put every photo in the text instead. Accepted types are JPEG, PNG, GIF and WebP.
- **Videos** (MP4, WebM, MOV) go to the media library too and play in the post.
- **Tags** go into the **Tags** taxonomy. A tag that matches an existing tag by its slug or name uses it; a new one is made. If the site has no Tags taxonomy, the post goes out without tags and NEFORUM says so.
- **Status**: `published` or `draft`, as set for the account. You can override it with **Publish as** in the post's **Customize** sheet. The order is: the post's own choice, then a choice kept for every post from the account (**Keep these for every EmDash post from this account** in the sheet), then the **Publish as** chosen when the account was connected, then published. A draft links to its page in the EmDash admin.
- **More options** in the **Customize** sheet: **Excerpt** (the post's excerpt) and **Address (slug)** (the post's address).
- **Address**: the post is at `https://your-site/posts/<slug>`. The slug is made from the title the way EmDash makes one.

### A retry never posts twice

The post is first saved as a draft, then published. Before it is sent, NEFORUM fixes its slug and marks every block of its text with a key made from the post. If a try fails halfway (for example the publish call gets no answer) and the post is sent again, EmDash answers that the slug is taken. NEFORUM then reads the post at that slug, sees its own mark and finishes that post instead of making a second one. The result says that it found the post from an earlier try.

If another post already has the slug, NEFORUM uses the slug with six characters of the key added (`my-title-3fa2c1`), and a retry looks there too. Files are uploaded with EmDash's duplicate check, so the same photo sent again is stored once.

## Limits

- **Only Administrators can make tokens.** Other roles use Hand-off.
- **No sound files.** EmDash's rich text has no audio block, so a track is left out.
- **The Posts collection.** NEFORUM posts to the `posts` collection with the address `/posts/<slug>`, as in EmDash's blog template. A site without it can only use Hand-off.
- **Token end date.** A token with an end date stops working then, and NEFORUM can't read that date. Reconnect with a new token.
- **No scheduling on the site.** A scheduled post stays on your device until its time.
- **Markdown rules.** Indented code (four spaces) and underlined headings (`===`) aren't read as Markdown, because social posts indent and underline text for other reasons.
- **No threads, no content warnings, no visibility.** Blog posts are single, public posts.

## Sources

- https://emdashcms.com
- https://github.com/emdash-cms/emdash
- https://github.com/emdash-cms/emdash/blob/main/packages/core/src/api/handlers/api-tokens.ts
- EmDash 1.5 source, read on 2026-11-13: `packages/core/src/astro/middleware/auth.ts` (token permissions per route), `packages/core/src/api/schemas/content.ts` (the post body), `packages/core/src/content/converters/types.ts` (Portable Text blocks), `packages/core/src/astro/routes/api/media.ts` (uploads)

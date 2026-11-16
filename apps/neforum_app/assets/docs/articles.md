# Articles: one post written for the blogs

An article is a long post laid out for a blog, with headings, photos and captions where you put them. When a blog is among the networks you post to (WordPress, Ghost, EmDash, WriteFreely or Write.as, DEV, Hashnode, a Micropub site, Tumblr, or Substack by hand-off), the composer can switch from **Post** to **Article**.

You write an article as blocks, in the order they are read: paragraphs, headings, photos, galleries, videos, sound, embeds, quotes, lists, code and dividers. An article also has a cover photo, a subtitle, an excerpt and the post's address. Each blog gets the article in its own format. The social networks in the same post get a short version: the words and files as one ordinary post.

## Steps

1. Pick where the post goes, including at least one blog. **Post** and **Article** appear above the editor. On a narrow screen such as a phone, where the accounts show as a grid, they appear under the post's text instead.
2. Tap **Article**. What you already wrote becomes blocks: a line that starts with `##` becomes a heading, lines that start with `-` become a list, and lines that start with `>` become a quote. The first photo that is not linked to a paragraph becomes the cover. A thread becomes one article.
3. Type the **Title** and, if you want one, the **Subtitle** at the top.
4. Write in the blocks. Two line breaks start a new paragraph. On a computer, Enter starts a new paragraph and Shift+Enter breaks the line; Backspace in an empty block removes it.
5. Format words with the buttons above the blocks, or with the keyboard: **Bold** is Ctrl+B, *Italic* is Ctrl+I, `Code` is Ctrl+E and a link is Ctrl+K (⌘ instead of Ctrl on a Mac). The formatting marks show as you type, as `**bold**`, `*italic*`, `` `code` `` and `[words](address)`, and you can type them yourself.
6. Tap **Add block** for a new block after the one you are in, or open a block's menu (the three dots) and pick **Add ... below**. A photo, gallery, video or sound block asks for its file: one of the post's files, or **Add from this device**.
7. Give a photo, video or sound its **Caption** and **Credit**. Give a photo or video its **Alt text**. Alt text belongs to the file, and every network uses it.
8. Move a block by dragging its handle (the dots on its left), with **Move up** and **Move down** in its menu, or with Alt+Shift+Up and Alt+Shift+Down on a computer. The same menu turns a text block into another kind, such as a paragraph into a heading or a list into a numbered list, and removes the block.
9. Open **Article details** to set:
   - the **Cover photo** and the **Excerpt**
   - the **Address ending**, also called the slug: leave it empty to have it made from the title, or tap the pencil to edit the one made from the title
   - **Tags** and the **Canonical URL**
   - **Publish as**: as each blog is set, published, or a draft
   - the schedule.
10. Look at each blog's preview before you post. It says what that blog will leave out of your article or change, such as "WordPress has no subtitle field; the subtitle is left out". To leave blocks or the cover out for that blog alone, tap **Choose what goes to ...**; **Everything** puts them back.
11. Publish, schedule or save the draft as usual.

To go back to a plain post, tap **Post**. If you change nothing in between, switching back and forth gives you exactly what you had: the plain post as you wrote it, and the article with its captions, galleries and details.

## How it works

### What each network gets

Each blog gets the article in its own format, built by the same code that shows the preview's report, so what the preview says is what is sent:

| Network | Format | Cover, excerpt and other details |
|---|---|---|
| WordPress | Block editor blocks | Featured image, excerpt, slug, draft |
| Ghost | Ghost cards | Feature image with its caption, custom excerpt (the subtitle when there is no excerpt), canonical URL, slug |
| EmDash | Portable Text | Featured image, excerpt, slug |
| WriteFreely, Write.as | Markdown | Cover at the top, tags as hashtags, slug |
| DEV | Markdown with `{% embed %}` | Main image, description, canonical URL, draft |
| Hashnode | Markdown with `%[address]` embeds | Cover image, subtitle, slug, original article address |
| Micropub | HTML in the JSON request | Featured photo, summary, slug, post status |
| Tumblr | NPF blocks, galleries in rows of three | Slug, source address from the canonical URL |
| Substack | Hand-off: formatted text on the clipboard | Title and subtitle to copy; `[Photo: file]` markers where you add the files |

X gets the article as an X Article only when **Post as an X Article** is on in Customize for an X account that posts with your own keys (X Articles need X Premium). Otherwise X, like every other social network, gets the short version.

When a blog cannot carry a block, its preview says so. A dropped block is listed as left out, as a warning. A changed block is listed as changed, as a note: for example, a gallery sent as photos one after the other, or a caption written as a line of text where Markdown has no captions. Nothing is left out without the preview saying so.

### The short version for the social networks

While you write the article, NEFORUM keeps the post's text, the order of its files and which paragraph each file follows in step with it. The social networks get that short version:

- the words without the blocks' structure: a heading becomes a line, and a list becomes lines
- the files in the article's order, with the cover first
- on networks that show paragraphs with their photos (Telegram, Discord), each photo after its paragraph.

A network that has its own words under **Differentiate** keeps them. A blog that has its own words gets those words instead of the article, and its preview says so.

Files you added to the post but did not place in the article stay in **Files in this post**, marked **Social only**: the blogs leave them out and the social networks get them.

### Pasting into a blog by hand

Some blogs are posted by hand-off, where you paste the post into the blog yourself. These are Substack, and a WordPress or Ghost account set up for hand-off. For them, NEFORUM copies the article as formatted text. Pasting it into the blog's editor keeps the headings, lists, links and bold; pasting it into a plain text field gives just the words. On the web, or where the system clipboard cannot take formatted text, NEFORUM copies the words as plain text.

### Saving and syncing

The article is saved inside the post, so drafts, scheduled posts and Sync carry it like the rest of the post. An older NEFORUM that does not know about articles opens the post with its short version. If a newer NEFORUM made a block this one does not know, the block is kept as it is and never sent, and the previews list it until you update NEFORUM.

### Why plain blocks

The editor is made of NEFORUM's own blocks, each a normal text field, rather than a rich text library. Before building it, the Flutter editors were compared (November 2026):

- super_editor (MIT): its last stable release, 0.2.7, is from June 2024, 0.3 is still in development releases, and pub.dev reports errors with current Flutter.
- appflowy_editor (MPL-2.0 or AGPL-3.0): last release December 2025, 165 open issues, and pub.dev reports errors.
- flutter_quill (MIT): active and on every platform, but its document is a flat run of text with attributes. Galleries, captions, credits, list numbering and quote citations would need a conversion that loses them.

With plain fields, every system's input methods, spell check, screen readers and keyboard work as they do in the rest of NEFORUM, and the emoji and symbol panels work in every block. The editor holds the article itself, so nothing is converted on the way in or out.

# Articles: one post written for the blogs

When a blog is among the networks you post to (WordPress, Ghost, EmDash, WriteFreely or Write.as, DEV, Hashnode, a Micropub site, Tumblr, or Substack by hand-off), the composer can switch from **Post** to **Article**. An article is written as blocks: paragraphs, headings, photos, galleries, videos, sound, embeds, quotes, lists, code and dividers, in the order they are read, with a cover photo, a subtitle, an excerpt and the post's address. Each blog gets the article in its own format, and the social networks of the same post get its short version: the words and files as one post.

## Steps

1. Pick where the post goes, with at least one blog. **Post** and **Article** appear above the editor.
2. Tap **Article**. What you already wrote becomes blocks: a line that starts with `##` becomes a heading, lines that start with `-` a list, lines that start with `>` a quote, and the first photo not linked to a paragraph becomes the cover. A thread becomes one article.
3. Type the **Title** and, if you want one, the **Subtitle** at the top.
4. Write in the blocks. Two line breaks start a new paragraph. On a computer, Enter starts a new paragraph and Shift+Enter breaks the line; Backspace in an empty block removes it.
5. Mark words with the buttons above the blocks, or with the keyboard: **Bold** is Ctrl+B, *Italic* Ctrl+I, `Code` Ctrl+E and a link Ctrl+K (⌘ instead of Ctrl on a Mac). The marks show as you type, as `**bold**`, `*italic*`, `` `code` `` and `[words](address)`, and you can type them yourself.
6. Tap **Add block** for a new block after the one you are in, or open a block's menu (the three dots) and pick **Add ... below**. A photo, gallery, video or sound block asks for its file: one of the post's files, or **Add from this device**.
7. Give a photo, video or sound its **Caption** and **Credit**, and a photo or video its **Alt text** (the file's own, used by every network).
8. Move a block by dragging its handle (the dots on its left), from its menu (**Move up**, **Move down**), or with Alt+Shift+Up and Alt+Shift+Down on a computer. Its menu also turns a text block into another kind (a paragraph into a heading, a list into a numbered list) and removes it.
9. Open **Article details** for the **Cover photo**, the **Excerpt**, the **Address ending** (slug: leave it empty to have it made from the title, or tap the pencil to edit the one made from the title), **Tags**, the **Canonical URL**, **Publish as** (as each blog is set, published, or a draft) and the schedule.
10. Look at each blog's preview. It says what that blog leaves out or changes of your article before you post, such as "WordPress has no subtitle field; the subtitle is left out". Tap **Choose what goes to ...** to leave blocks or the cover out for that blog alone; **Everything** puts them back.
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

A blog that cannot carry a block shows it in its preview: dropped blocks are listed as left out (a warning), changed ones as changed (a note, such as a gallery sent as photos one after the other, or a caption written as a line of text where Markdown has no captions). Nothing is left out without the preview saying so.

### The short version for the social networks

While you write the article, the post's text, the order of its files and which paragraph each file follows are kept in step with it. The social networks get those: the words without the blocks' structure (a heading as a line, a list as lines), the files in the article's order with the cover first, and on networks that show paragraphs with their photos (Telegram, Discord) each photo after its paragraph. A network with **Differentiate** words of its own keeps them; a blog with words of its own gets those words instead of the article, and its preview says so.

Files you added to the post but did not place in the article stay in **Files in this post**, marked **Social only**: the blogs leave them out and the social networks get them.

### Pasting into a blog by hand

A blog posted by hand-off (Substack, or a WordPress or Ghost account set up for hand-off) copies the article as formatted text: pasting it into the blog's editor keeps the headings, lists, links and bold, and a plain text field gets the words. On the web, or where the system clipboard cannot take formatted text, the words are copied as text.

### Saving and syncing

The article is saved inside the post, so drafts, scheduled posts and Sync carry it like the rest of the post. A NEFORUM that does not know articles yet opens the post with its short version. A block made by a newer NEFORUM is kept as it is, never sent, and listed in the previews until NEFORUM is updated.

### Why plain blocks

The editor is made of NEFORUM's own blocks, each a normal text field, rather than a rich text library. Before building it, the Flutter editors were compared (November 2026): super_editor (MIT; its last stable release, 0.2.7, is from June 2024, 0.3 is still in development releases, and pub.dev reports errors with current Flutter), appflowy_editor (MPL-2.0 or AGPL-3.0; last release December 2025, 165 open issues, pub.dev reports errors) and flutter_quill (MIT; active, every platform, but its document is a flat run of text with attributes, so galleries, captions, credits, list numbering and quote citations would need a conversion that loses them). Plain fields keep every system's input methods, spell check, screen readers and keyboard as they are in the rest of NEFORUM, the emoji and symbol panels work in every block, and the editor holds the article itself, so nothing is converted on the way in or out.

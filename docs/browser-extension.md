# NEFORUM browser extension (Chrome and Firefox)

The extension finishes hand-offs for you. When you click **Open** in a NEFORUM hand-off, the platform's page opens in your browser and the extension fills in the post: the text, poll answers, photos and videos. You check it, then post it with one key: **Ctrl+Enter** (**⌘+Enter** on a Mac).

It works in Google Chrome and Mozilla Firefox (and other Chromium browsers such as Microsoft Edge, Brave and Opera, from the Chrome version).

## What it fills in

| Site | What happens |
|---|---|
| YouTube Posts | Opens the post box on your channel's Posts tab, types the text, and adds images after choosing the image option. |
| TikTok Studio | Uploads the photos or video, then replaces the file name TikTok puts in the caption with your caption. |
| Instagram (web) | Create > Post, uploads the files, goes through the two Next screens and types the caption. |
| Substack Notes | Opens "What's on your mind?" (or Create > Note), types the text and adds the images. |
| Facebook | Opens "What's on your mind?" when needed, types the text and adds the media. |
| X, Bluesky, Threads, LinkedIn, Reddit, Tumblr | Their composer links already carry the text; the extension adds the photos and videos. |
| Pinterest | Uploads the image, then fills in the title and description. |
| WhatsApp Web, Snapchat, Google Business Profile | Types the text and adds the media where the page allows. |
| Any other site (your Mastodon server, a blog) | Click the extension's icon, then **Fill in this page**. |

A small NEFORUM panel shows on the page while it works. It says what was filled in. **Fill in again** repeats it. **Insert text** puts the text into the box you clicked last, and **Attach** adds the files again. Poll answers and other snippets each have **Copy** and **Insert**.

## Post with one key

When the page is filled in, the panel shows **Post now** and says "press Ctrl+Enter". Check the post, then press **Ctrl+Enter** (**⌘+Enter** on a Mac) or click **Post now**: the extension presses the site's Post, Share or Publish button for you.

- **It only ever posts when you press the key or click Post now.** Never on its own, never on a timer. Key presses made by scripts don't count.
- **If an upload is still running**, the site's button is greyed out. The extension waits for it ("Waiting for TikTok to be ready…"). Press **Esc** or **Stop** to cancel.
- **Typing somewhere else on the page** (a search box, a chat) keeps Ctrl+Enter for that box: the extension only reacts when you're in the composer or nowhere in particular.
- **Once per hand-off.** Pressing again, or reloading the page, does not post a second time.
- **Facebook's Next screen** is gone through for you when it appears before Post.
- **When the post went out** (the composer closed or emptied), NEFORUM marks the hand-off as posted and moves on to the next one. If the page gave no sign, the hand-off says so, and you click **I posted it** once you've checked.
- If the extension can't find the Post button, it leaves Ctrl+Enter to the site (X, Bluesky and Mastodon post on Ctrl+Enter themselves) and tells you to press Post.

A word of caution: the click is still made by the extension, and some platforms count scripted clicks as automation. NEFORUM keeps you in control of every single post, which is the difference between this and a posting bot, but if you'd rather click Post yourself, turn off **Settings > Browser extension > Post with Ctrl+Enter**.

## Chrome and Firefox on one computer

Pair both if you use both. The paired browsers are listed in order of choice, and the first one gets **First choice**:

- Hand-offs open in your first choice (not your system's default browser), and only that browser fills them in on its own. The other one stays quiet, so the post isn't filled in twice. You can still use **Fill in this page** in it.
- **Swap** trades the first two places (Chrome and Firefox swap). With more browsers, the arrow next to one makes it the first choice.
- If the first choice isn't installed any more or won't start, the next one is used; if none, your default browser, and any paired browser fills in.
- Turn off **Open hand-offs in my first-choice browser** to always use your default browser.

## Install

The extension is not in the Chrome Web Store or on Firefox Add-ons yet, so you install it from the files that come with NEFORUM. In NEFORUM open **Settings > Browser extension > Show extension files**. It opens a folder with a `chrome` and a `firefox` folder inside.

**Chrome, Edge, Brave, Opera**

1. Open `chrome://extensions` (Edge: `edge://extensions`).
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and choose the `chrome` folder.
4. Pin the NEFORUM icon to the toolbar (puzzle piece > pin).

Chrome keeps the extension after a restart. It may show a reminder that a developer-mode extension is installed; that's expected for extensions not from the store.

**Firefox**

1. Open `about:debugging#/runtime/this-firefox`.
2. Click **Load Temporary Add-on…** and choose `manifest.json` in the `firefox` folder.
3. Click the NEFORUM icon (puzzle piece if hidden) and **Allow on supported sites**: Firefox asks before an extension may work on a site.

Firefox removes a temporary add-on when it closes. For a permanent install it needs to be signed by Mozilla, which happens when it is published on addons.mozilla.org (or, for testing, use Firefox Developer Edition with `xpinstall.signatures.required` set to false).

## Pair it with NEFORUM

1. In NEFORUM open **Settings > Browser extension** and click **Pair a browser**. A 6-digit code appears for 5 minutes.
2. Click the NEFORUM icon in the browser and type the code.

That's all. NEFORUM lists the paired browser, and you can remove it there at any time. Pair each browser you use once.

## How it stays private

- The extension talks only to NEFORUM on your own computer (`127.0.0.1`, ports 52772 to 52779). Nothing goes to Neforus or anywhere else.
- Only a paired browser can ask NEFORUM for anything; pairing needs the code shown in NEFORUM. Websites cannot read from NEFORUM: it refuses requests from web pages and sends no headers that would let a page read its answers.
- NEFORUM hands over one post at a time, only after you click **Open**, and forgets it after 10 minutes.
- The extension reads nothing from the sites except what it needs to find the composer and its Post button, and sends back only "filled in / partly / failed" (and "posted", after you posted with the key) so the hand-off can say how it went.

The full protocol is in `extensions/browser/PROTOCOL.md` in the repository.

## When it can't fill something in

Sites change their pages, so a step can stop working. The panel then says what is missing, for example "Could not find the text box". Click into the box and use **Insert text**. Or use the hand-off as before: the text is on your clipboard (Ctrl+V or ⌘V), and **Copy photo** / **Save media to Downloads** are in NEFORUM.

If the extension does not react at all:

- Check that NEFORUM is running and **Settings > Browser extension** is on.
- Click the NEFORUM icon in the browser: it says whether it can reach NEFORUM and is paired.
- In Firefox, make sure you clicked **Allow on supported sites**.
- The hand-off waits 10 minutes. After that, click **Open** in NEFORUM again.

## Publishing it in the stores (for the maintainer)

`dart run tool/build_extension.dart` (in `apps/neforum_app`) builds both versions and writes upload-ready zips to `dist/`: `neforum-extension-chrome-<version>.zip` for the Chrome Web Store (a developer account costs a one-time US$5) and `neforum-extension-firefox-<version>.zip` for addons.mozilla.org (free; the add-on id is `neforum-extension@neforus.com`). Store review checks the permissions: the extension uses `storage`, `scripting`, `activeTab`, host access to `127.0.0.1`, and content scripts on the platforms listed above.

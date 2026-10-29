# NEFORUM browser extension

The NEFORUM extension for Chrome and Firefox finishes hand-offs for you: it fills in the post on the platform's own page (text, thread parts, poll answers, photos, videos, artwork details), and you post it with one key. If you turn on automatic posting, it also presses Post for you after a 3-second countdown.

## Steps: install in Chrome, Edge, Brave or Opera

1. In NEFORUM open **Settings > Browser extension** and click **Show extension files**. A folder opens with a `chrome` and a `firefox` folder inside.
2. In the browser, open `chrome://extensions` (Edge: `edge://extensions`).
3. Turn on **Developer mode** (top right).
4. Click **Load unpacked** and choose the `chrome` folder.
5. Pin the NEFORUM icon to the toolbar (puzzle piece > pin).

## Steps: install in Firefox

1. In NEFORUM open **Settings > Browser extension** and click **Show extension files**.
2. In Firefox, open `about:debugging#/runtime/this-firefox`.
3. Click **Load Temporary Add-on…** and choose `manifest.json` in the `firefox` folder.
4. Click the NEFORUM icon (under the puzzle piece if hidden) and choose **Allow on supported sites**.

## Steps: pair it with NEFORUM

1. In NEFORUM open **Settings > Browser extension** and click **Pair a browser**. A 6-digit code appears for 5 minutes.
2. Click the NEFORUM icon in the browser and type the code.
3. Pair each other browser you use the same way, once.

## Steps: finish a hand-off

1. In the NEFORUM hand-off, click **Open**. The platform's page opens in your browser and the extension fills in the post.
2. Check the post on the page.
3. Press **Ctrl+Enter** (**⌘+Enter** on a Mac), or click **Post now** in the NEFORUM panel on the page.

## Steps: post automatically

1. In NEFORUM open **Settings > Browser extension** and turn on **Post automatically**.
2. Under **Networks that post automatically**, tap a network to leave it out, or to put it back in.
   - X, LinkedIn and Snapchat start left out: their terms forbid scripted posting and they can suspend accounts for it.
3. Keep NEFORUM open on this computer, so scheduled posts go out at their time.

## How it works

The extension works in Google Chrome and Mozilla Firefox, and in other Chromium browsers such as Microsoft Edge, Brave and Opera (from the Chrome version).

When you click **Open** in a hand-off, NEFORUM gives the post to the extension and opens the platform's page. A small NEFORUM panel shows on the page while it works and says what was filled in. **Fill in again** repeats it. **Insert text** puts the text into the box you clicked last, and **Attach** adds the files again. Poll answers, tags, the other parts of a thread and other snippets each have **Copy** and **Insert**.

### What it fills in

| Site | What happens |
|---|---|
| X, Bluesky, Threads | The composer link carries the first part; the extension adds the photos or videos, then adds a post for each other part of a thread and fills it in. |
| Mastodon (your server) | Click the extension's icon, then **Fill in this page**: it adds the files. Mastodon's composer holds one post, so the other parts of a thread are in the panel to post as replies. |
| YouTube Posts | Opens the post box on your channel's Posts tab, types the text, adds images after choosing the image option, or chooses the poll, quiz or image poll option, fills in the answers (one image per answer for an image poll), marks the correct quiz answer and adds the explanation. |
| YouTube (video upload) | `youtube.com/upload` opens YouTube Studio's upload window: the extension adds the video, replaces the file name YouTube puts in the title with your title, and fills in the description and the tags. You answer "made for kids" and publish. |
| TikTok Studio | Uploads the photos or video, then replaces the file name TikTok puts in the caption with your caption. |
| Instagram (web) | Create > Post, uploads the files, goes through the two Next screens and types the caption. |
| Substack Notes | Opens "What's on your mind?" (or Create > Note), types the text and adds the images. |
| Facebook | Opens "What's on your mind?" when needed, types the text and adds the media. |
| Tumblr | Opens Tumblr's full editor for the kind of post (`/new/text`, `/new/photo`, `/new/video`, `/new/link`, `/new/quote`, `/new/chat` or `/new/audio`, not the text-only share tool), types the text, adds the photos or video and the tags. In a link post the link goes into Tumblr's URL field and becomes a link card; in an audio post the track's link becomes the player. |
| LinkedIn, Reddit | Their composer links already carry the text; the extension adds the photos and videos. |
| Pinterest | Uploads the image, then fills in the title and description. |
| WhatsApp Web | `wa.me` links forward to WhatsApp Web; once you choose a chat, the extension types the text and adds the media (click **Fill in again** if the chat was not open yet). |
| Snapchat, Google Business Profile | Types the text and adds the media where the page allows. |
| Behance, ArtStation, Cara, pixiv, Itaku, Newgrounds, Fur Affinity, Weasyl, Ko-fi, Artfol, 500px, Dribbble, Flickr | Opens the upload page, adds the images, fills in the title, description and tags, and sets the age rating and the "made with AI" and "no AI training" options where the form has them. It finds each field by the words that label it. |
| Any other site (a blog) | Click the extension's icon, then **Fill in this page**. |

### Post with one key

When the page is filled in, the panel shows **Post now** and says "press Ctrl+Enter". Check the post, then press **Ctrl+Enter** (**⌘+Enter** on a Mac) or click **Post now**: the extension presses the site's Post, Share or Publish button for you.

- **Without automatic posting, it only posts when you press the key or click Post now.** Key presses made by scripts don't count.
- **If an upload is still running**, the site's button is greyed out. The extension waits for it ("Waiting for TikTok to be ready…"). Press **Esc** or **Stop** to cancel.
- **Typing somewhere else on the page** (a search box, a chat) keeps Ctrl+Enter for that box: the extension only reacts when you're in the composer or nowhere in particular.
- **Once per hand-off.** Pressing again, or reloading the page, does not post a second time.
- **Facebook's Next screen** is gone through for you when it appears before Post. A confirmation some sites show after Post (Flickr's "Upload", Itaku's rating check) is answered too, unless you pressed **Esc** or **Stop** after Post: then it is yours to answer.
- **When the post went out** (the composer closed or emptied), NEFORUM marks the hand-off as posted and moves on to the next one. If the page gave no sign, the hand-off says so, and you click **I posted it** once you've checked.
- If the extension can't find the Post button, it leaves Ctrl+Enter to the site (X, Bluesky and Mastodon post on Ctrl+Enter themselves) and tells you to press Post.

### Automatic posting

With **Post automatically** on, a hand-off for a network that is not left out goes like this, on a computer with a paired browser:

- The hand-off opens the page in your browser by itself, with no click.
- The extension fills in everything it can. Only when everything went in does it show a 3-second countdown in its panel, with **Stop** (or **Esc**). Then it presses the site's Post button, checks that the post went out, and NEFORUM marks the hand-off as done and moves on to the next one.
- **Stop** and **Esc** work from the moment the extension starts filling in until it presses Post, also while it waits for an upload or checks with NEFORUM. After either one, nothing is posted by itself.
- If anything is missing (a field it could not find, a rating it could not set, a part of a thread), or the site needs a choice only you can make, it does not post. The page stays filled in, the hand-off sheet says why, and you finish it as usual. Sites that always need you: Reddit (community and flair), WhatsApp (who gets it), YouTube video uploads ("made for kids"), Behance (cover and creative field), Newgrounds (rating questions and terms), Fur Affinity (its pages).
- Right before it presses Post, the extension asks NEFORUM again. Closing the hand-off (**Later**, **Skip**), opening the page again from it, or **Cancel** in Activity therefore stops it, even while it waits for an upload.
- Only the page NEFORUM opened posts. Another tab of the same site gets the post to fill in, never to post, and what it reports does not change how the hand-off goes. A post you make from that tab with **Post now** or Ctrl+Enter still counts, and the page NEFORUM opened then does not post it again.
- When the page was filled in but the post was not seen going out (Post pressed without a sign, the countdown stopped, something left for you), the hand-off keeps a note saying what to check, also when you close it with **Later**. The hand-off, the post's details and the notification show the note, and that hand-off is never posted automatically again: you finish it, or mark it as posted.
- **Scheduled posts** go out the same way at their time while NEFORUM is open on this computer, without the hand-off sheet. If one does not post, it waits with the usual "Time to post" notification.
- Only networks whose pages the extension fills in by itself can post automatically, so **Networks that post automatically** lists only those. A network where you have more than one account always waits for you: the browser posts as whichever account is signed in there.
- The extension presses Post by itself only for hand-offs NEFORUM marks automatic, and NEFORUM marks them only when you turned automatic posting on, for that network. The demo workspace never gives the extension anything, so its sample posts stay in NEFORUM. Phones cannot run the extension, so there it does nothing.

Some platforms treat scripted posting as automation and can restrict accounts for it. X, LinkedIn and Snapchat forbid it in their terms, so they are left out until you put them in (NEFORUM warns you when you do). If you'd rather click Post yourself everywhere, keep **Post automatically** off; to also stop the one-key posting, turn off **Post with Ctrl+Enter**.

### Which browser is which ("Opens in")

Each paired browser in **Settings > Browser extension** has **Opens in**: the program it really is, and where NEFORUM opens hand-offs for it. The list is the browsers Windows knows about (the same list as Default Apps), the browser apps on a Mac, or the browser commands on Linux.

NEFORUM guesses it when you pair: "Firefox" is Mozilla Firefox, "Chrome" is Google Chrome. Many browsers are built on Chromium (Helium, Vivaldi, Thorium, ungoogled Chromium...) and can look just like Chrome to the extension; some even use the same program file name, `chrome.exe`. So if you paired one of those, pick it under **Opens in**. On Windows and Linux, **Other program…** lets you choose a browser that isn't listed, such as a portable one.

### Chrome and Firefox on one computer

Pair both if you use both (or any two browsers: Chrome and Helium, Edge and Firefox). The paired browsers are listed in order of choice, and the first one gets **First choice**:

- Hand-offs open in your first choice (not your system's default browser), and only that browser fills them in on its own. The other one stays quiet, so the post isn't filled in twice. You can still use **Fill in this page** in it.
- **Swap** trades the first two places (Chrome and Firefox swap). With more browsers, the arrow next to one makes it the first choice.
- Only the browser set to the program NEFORUM opened fills the page in on its own, so Chrome and Helium never both fill in the same post.
- If the first choice isn't installed any more or won't start, the next one is used; if none, your default browser, and any paired browser fills in.
- Turn off **Open hand-offs in my first-choice browser** to always use your default browser.

### How it stays private

- The extension talks only to NEFORUM on your own computer (`127.0.0.1`, ports 52772 to 52779, or 41772 to 41779 when those can't be used). Nothing goes to Neforus or anywhere else.
- Only a paired browser can ask NEFORUM for anything; pairing needs the code shown in NEFORUM. Websites cannot read from NEFORUM: it refuses requests from web pages and sends no headers that would let a page read its answers.
- NEFORUM hands over one post at a time, only when a hand-off opens the page, and forgets it after 10 minutes.
- The extension reads nothing from the sites except what it needs to find the composer, its fields and its Post button, and sends back only "filled in / partly / failed", "posted" and, for automatic posting, "counting down / stopped / not posted automatically", so the hand-off can say how it went.

The full protocol is in `extensions/browser/PROTOCOL.md` in the repository.

### When NEFORUM is not paired with a browser

Without the extension (on a phone, or on a computer with no paired browser), hand-offs work by copying. NEFORUM copies the text first; after you paste it in the other app and come back to NEFORUM, the next part (a snippet, then each photo) is already on the clipboard, and the hand-off says what it is ("Photo 2 of 3 copied. Paste it."). A photo that cannot be copied is skipped, and the hand-off says so. The switch **Copy the next part when I come back** in the hand-off (and, on a computer, in **Settings > Browser extension**) turns this off. On Android, **Share** opens the network's own app directly when it is installed (its caption is on the clipboard and in the share), and the system share sheet when it is not; iPhones and iPads keep the share sheet.

## Limits

- The extension is not in the Chrome Web Store or on Firefox Add-ons yet, so you install it from the files that come with NEFORUM.
- Chrome keeps the extension after a restart. It may show a reminder that a developer-mode extension is installed; that's expected for extensions not from the store.
- Firefox removes a temporary add-on when it closes. For a permanent install it needs to be signed by Mozilla: when a GitHub release has `neforum-extension-firefox-<version>.xpi` (signed by Mozilla for self-distribution), open that file in Firefox to install it for good. Otherwise it happens when it is published on addons.mozilla.org (or, for testing, use Firefox Developer Edition with `xpinstall.signatures.required` set to false).
- Mastodon, Misskey and blogs run on their own addresses, which the extension does not know in advance: use **Fill in this page** there. Automatic posting cannot start there by itself.
- The site recipes follow each site's page as it was known when this version was made, and the art sites' upload forms could not be studied signed in. When a site changes, the extension says what it could not do, does not post automatically, and you finish by hand.
- Automatic posting needs NEFORUM running on a computer with a paired browser; phones cannot do it.

## Troubleshooting

### When it can't fill something in

Sites change their pages, so a step can stop working. The panel then says what is missing, for example "Could not find the text box". Click into the box and use **Insert text**. Or use the hand-off as before: the text is on your clipboard (Ctrl+V or ⌘V), and **Copy photo** / **Save media to Downloads** are in NEFORUM.

### If the extension does not react at all

- Check that NEFORUM is running and **Settings > Browser extension** is on.
- Click the NEFORUM icon in the browser: it says whether it can reach NEFORUM and is paired.
- In Firefox, make sure you clicked **Allow on supported sites**.
- The hand-off waits 10 minutes. After that, click **Open** in NEFORUM again.
- An extension older than 1.1.0 fills pages in but never posts by itself; the hand-off says so. Load the new version from **Show extension files** (Chrome: the reload arrow on the NEFORUM card in `chrome://extensions`; Firefox: load `manifest.json` from the new `firefox` folder again).

### If the extension cannot find NEFORUM on Windows

NEFORUM listens on one of ports 52772 to 52779. Those are in the range Windows hands out on its own (49152 to 65535), and Hyper-V, which WSL, Docker and Windows Sandbox use, reserves random blocks of that range each time Windows starts. When it has taken NEFORUM's ports, NEFORUM can't open them.

NEFORUM then moves on to ports 41772 to 41779, below that range, so it keeps working. **Settings > Browser extension** shows the port it listens on. The extension only looks on those ports from **version 1.0.1**, so update it:

- **Chrome, Edge, Brave, Opera**: after updating NEFORUM, open `chrome://extensions` and click the reload arrow on NEFORUM (if you loaded the `chrome` folder from **Show extension files**; if you copied it somewhere else, load the new folder instead). The card shows the version (now 1.1.1).
- **Firefox**: load `manifest.json` from the new `firefox` folder again (see the install steps).

If the status says **Ports blocked**, Windows refused every one of NEFORUM's ports. Restarting the computer usually changes which ports are reserved. To see the reserved ranges, run `netsh interface ipv4 show excludedportrange protocol=tcp` in a terminal.

### Publishing it in the stores (for the maintainer)

`dart run tool/build_extension.dart` (in `apps/neforum_app`) builds both versions and writes upload-ready zips to `dist/`: `neforum-extension-chrome-<version>.zip` for the Chrome Web Store (a developer account costs a one-time US$5) and `neforum-extension-firefox-<version>.zip` for addons.mozilla.org (free; the add-on id is `neforum-extension@neforus.com`). Store review checks the permissions: the extension uses `storage`, `scripting`, `activeTab`, host access to `127.0.0.1` (any port: the match pattern `http://127.0.0.1/*` covers both port ranges), and content scripts on the platforms in the table above (YouTube Studio and the art sites since 1.1.0). The Chrome Web Store's developer agreement forbids extensions that knowingly break a site's terms; automatic posting is off by default and leaves out the networks whose terms forbid it. The listing text, permission justifications, privacy answers and reviewer notes are ready in [docs/chrome-web-store.md](https://github.com/Neforuss/NEFORUM/blob/main/docs/chrome-web-store.md) and [docs/firefox-amo.md](https://github.com/Neforuss/NEFORUM/blob/main/docs/firefox-amo.md); signing is in [docs/signing.md](https://github.com/Neforuss/NEFORUM/blob/main/docs/signing.md).

## Sources

- X automation rules (no scripting of the X website): https://help.x.com/en/rules-and-policies/x-automation
- LinkedIn on extensions that automate activity: https://www.linkedin.com/help/linkedin/answer/a1341387
- Snap terms of service (automated or semi-automated means): https://snap.com/en-US/terms
- YouTube Help, create a post (polls, quizzes, images): https://support.google.com/youtube/answer/7124474

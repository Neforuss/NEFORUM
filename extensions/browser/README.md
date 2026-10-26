# NEFORUM browser extension

Fills in NEFORUM hand-offs on the platforms' websites (Chrome and Firefox, Manifest V3). User guide: [docs/browser-extension.md](../../docs/browser-extension.md). App protocol: [PROTOCOL.md](PROTOCOL.md).

```
src/background.js        talks to the NEFORUM app on 127.0.0.1, ports 52772-52779 then 41772-41779 (pairing, jobs, media in chunks)
src/content/fill.js      puts text into any editor (React inputs, Draft.js, Lexical, ProseMirror) and files into inputs, pastes, drops;
                         finds form fields by the words that label them (title, tags, ratings, tick boxes)
src/content/recipes.js   per-platform steps (open the composer, media first or not, where the caption is, thread parts,
                         poll and quiz answers, tags, the art sites' upload forms)
src/content/panel.js     the in-page panel (shadow DOM), with the countdown and Stop of automatic posting
src/content/main.js      fetches the job, runs the recipe, reports back, posts (shortcut, or automatic jobs)
src/popup/               pairing, status, "Fill in this page"
manifest.chrome.json     service worker background
manifest.firefox.json    event-page background, gecko id
```

Build both versions into the app's assets and `dist/` zips:

```bash
cd apps/neforum_app && dart run tool/build_extension.dart
```

Icons come from `tool/generate_icons.dart` (same geometry as the app icon).

## Tests

- `node --test extensions/browser/test/background.test.mjs`: the background script against a stand-in app that follows PROTOCOL.md (the port list, discovery, pairing, jobs, chunked media, revoked tokens). The stand-in uses free ports of its own, never the real ones. `PORTS` must stay the same as `kBrowserBridgePorts` in the app (`apps/neforum_app/lib/platform/browser_bridge.dart`); the app's `test/browser_bridge_test.dart` checks that.
- `node --test extensions/browser/test/content.test.mjs`: the content scripts without a page: the text helper that keeps a prefilled first part from going in twice, a thread's new post box judged by itself, the recipe table (thread parts, YouTube, the art sites, which sites always leave posting to the user), pixiv's mature rating and the manifests (version, the same pages in both, the art sites and YouTube Studio).
- `node --test extensions/browser/test/main.test.mjs`: `main.js` on a stand-in page with a stand-in NEFORUM: an automatic job asks NEFORUM again right before Post and presses nothing once the job was dropped, replaced or no longer automatic; Stop or Esc pressed while NEFORUM is asked, or while the page is still being filled in, keeps it unposted, and after Esc a site's question after Post is left to the user; the page id goes with every request and every report; a Post that loaded a new page is reported from that page once; a report NEFORUM did not take shows on the page.
- `test/pages/thread.html?p=x`: an X-like thread composer whose link prefilled the first part; every part must end up in its own box exactly once (`window.postBoxes()`). With `&auto=1` the job is automatic: filled in, the 3-second countdown, then **Post all** is pressed once.
- `test/pages/artwork.html?p=itaku`: an art site's upload form (Angular-style fields, a tag box that makes chips on Enter, a maturity question with hidden radio buttons, a confirmation dialog after Submit). `&rating=adult|mature|general` changes the job's rating (`window.form()`). `?p=kofi&auto=1&rating=adult` must not post: that recipe cannot set an adult rating.
- `test/pages/youtube_posts.html?p=youtube_posts&kind=poll|quiz`: a post box shaped like YouTube's; the answers, the correct quiz answer and the explanation are filled in (`window.poll()`).
- Automatic posting on `post.html`: `?auto=1` waits for the "upload", counts down and presses the composer's Post (never the decoy); press Esc during the countdown and nothing is posted (`window.__results` ends with `automatic: "stopped"`); `?auto=1&p=reddit` fills in but reports `automatic: "manual"` (Reddit needs the user).
- `test/pages/editors.html` and `test/pages/composer.html`: serve this folder (`python -m http.server 8791 --directory extensions/browser`) and run `fill.js` / the whole content flow against real Draft.js, Lexical and ProseMirror editors, a React-controlled textarea, file inputs, paste and drop targets.
- `test/pages/post.html`: the real content scripts with a stand-in background (`harness.js`), for the Post shortcut. Serve this folder (`node tool/serve_web.js 8766 extensions/browser` from the repository root), open `http://127.0.0.1:8766/test/pages/post.html`, and press Ctrl+Enter yourself (a script's key press must not post). It has a decoy Post button and a search box that must be left alone, a Post button greyed out during an "upload", and `?next=1` (a Next screen first, with `?p=facebook`), `?inline=1` (the composer empties instead of closing), `?qp=0` (posting not allowed), `?pref=0` (opened in the other browser: nothing happens). `window.__results` has what was reported.
- `test/pages/blocks.html?p=tumblr`: a Tumblr-like editor where every paragraph is its own editable block and a paste turns into new blocks a moment later. The text must go in exactly once (`window.postText()`), also after **Fill in again**.
- `test/pages/new/audio.html?p=tumblr`: a Tumblr-like audio post: the track (the job's "Track link" snippet) goes into the search-or-URL field and becomes a player, the text into the blocks.
- `test/pages/new/link.html?p=tumblr`: a Tumblr-like link post (served under `.../new/link` so the link-post steps run): the link goes into the URL field and becomes a card, the rest of the text into the blocks without the link (`window.result()`).

The recipes for live sites (YouTube, TikTok Studio, Instagram, Substack, Facebook, the art sites…) use the sites' current page structure where known and fall back to generic detection; they cannot be tested here without signing in, so when a site changes, the panel says what it could not do, automatic posting does not go ahead, and the user finishes by hand.

Rule: the extension presses a platform's Post / Share / Publish button only for the user's real Ctrl+Enter (⌘+Enter) or Post now click, after filling in, once per job, when NEFORUM's job allows it (`quickPost`), or for a job NEFORUM marks automatic (`autoPost`, which it sets only when the user turned on automatic posting for that network): then only after everything was filled in, after a 3-second countdown the user can stop, never after the user pressed Stop or Esc (from the start of the fill to the press, a confirmation after Post included), never for a site whose recipe has `manualPublish`, never after Fill in again or a reload, only on the one page NEFORUM lets post the job, and only when NEFORUM, asked again right before the press, still says so. See PROTOCOL.md.

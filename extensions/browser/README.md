# NEFORUM browser extension

Fills in NEFORUM hand-offs on the platforms' websites (Chrome and Firefox, Manifest V3). User guide: [docs/browser-extension.md](../../docs/browser-extension.md). App protocol: [PROTOCOL.md](PROTOCOL.md).

```
src/background.js        talks to the NEFORUM app on 127.0.0.1 (pairing, jobs, media in chunks)
src/content/fill.js      puts text into any editor (React inputs, Draft.js, Lexical, ProseMirror) and files into inputs, pastes, drops
src/content/recipes.js   per-platform steps (open the composer, media first or not, where the caption is)
src/content/panel.js     the in-page panel (shadow DOM)
src/content/main.js      fetches the job, runs the recipe, reports back
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

- `node --test extensions/browser/test/background.test.mjs`: the background script against a stand-in app that follows PROTOCOL.md (discovery, pairing, jobs, chunked media, revoked tokens).
- `test/pages/editors.html` and `test/pages/composer.html`: serve this folder (`python -m http.server 8791 --directory extensions/browser`) and run `fill.js` / the whole content flow against real Draft.js, Lexical and ProseMirror editors, a React-controlled textarea, file inputs, paste and drop targets.
- `test/pages/post.html`: the real content scripts with a stand-in background (`harness.js`), for the Post shortcut. Serve this folder (`node tool/serve_web.js 8766 extensions/browser` from the repository root), open `http://127.0.0.1:8766/test/pages/post.html`, and press Ctrl+Enter yourself (a script's key press must not post). It has a decoy Post button and a search box that must be left alone, a Post button greyed out during an "upload", and `?next=1` (a Next screen first, with `?p=facebook`), `?inline=1` (the composer empties instead of closing), `?qp=0` (posting not allowed), `?pref=0` (opened in the other browser: nothing happens). `window.__results` has what was reported.
- `test/pages/blocks.html?p=tumblr`: a Tumblr-like editor where every paragraph is its own editable block and a paste turns into new blocks a moment later. The text must go in exactly once (`window.postText()`), also after **Fill in again**.

The recipes for live sites (YouTube, TikTok Studio, Instagram, Substack, Facebook…) use the sites' current page structure where known and fall back to generic detection; they cannot be tested here without signing in, so when a site changes, the panel says what it could not do and the user finishes by hand.

Rule: the extension never presses a platform's Post / Share / Publish button on its own: only for the user's real Ctrl+Enter (⌘+Enter) or Post now click, after filling in, once per job, and only when NEFORUM's job allows it (`quickPost`). See PROTOCOL.md.

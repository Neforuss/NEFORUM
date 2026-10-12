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

The recipes for live sites (YouTube, TikTok Studio, Instagram, Substack, Facebook…) use the sites' current page structure where known and fall back to generic detection; they cannot be tested here without signing in, so when a site changes, the panel says what it could not do and the user finishes by hand.

Rule: the extension never presses a platform's Post / Share / Publish button.

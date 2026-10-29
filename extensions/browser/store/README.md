# Store images

Pictures for the Chrome Web Store and addons.mozilla.org listings (text in
[docs/chrome-web-store.md](../../../docs/chrome-web-store.md) and
[docs/firefox-amo.md](../../../docs/firefox-amo.md)).

| File | Size | Where |
|---|---|---|
| `images/icon-128.png` | 128 x 128 | Chrome: store icon |
| `images/promo-tile-440x280.png` | 440 x 280 | Chrome: small promo tile (required) |
| `images/marquee-1400x560.png` | 1400 x 560 | Chrome: marquee promo tile (optional) |
| `images/screenshot-1-popup.png` … `screenshot-4-settings.png` | 1280 x 800 | Both stores: screenshots |

Screenshots 1 and 2 show the extension's own popup (`src/popup`) and panel
(`src/content/panel.js`) on a neutral demo page; 3 and 4 are NEFORUM's
screens from `apps/neforum_app/test/screenshots_test.dart` (the `store:`
tests, written to `test/goldens/store-*.png`).

To make 1 and 2 and the tiles again, put the pages in `source/` in a folder
next to these copies, then let Edge (or Chrome) take the pictures:

```powershell
$work = "$env:TEMP\neforum-store"; New-Item -ItemType Directory -Force $work | Out-Null
Copy-Item source\* $work; Copy-Item ..\src $work\ext -Recurse -Force
Copy-Item ..\..\..\apps\neforum_app\assets\brand\icon.png $work
New-Item -ItemType Directory -Force $work\fonts | Out-Null
Copy-Item ..\..\..\apps\neforum_app\assets\fonts\BricolageGrotesque-ExtraBold.ttf, ..\..\..\apps\neforum_app\assets\fonts\Inter-Regular.ttf, ..\..\..\apps\neforum_app\assets\fonts\Inter-SemiBold.ttf $work\fonts
# shot1-popup.html shows ext/popup/popup-shot.html: popup.html with the
# "ready" section shown, the status "Paired with NEFORUM on this computer."
# and no script.
```

Then, for each page (`--window-size` 1280,800 for the shots; 440,280 and
1400,560 with `?w=…&h=…` for `tile.html`):

```powershell
msedge --headless=new --hide-scrollbars --allow-file-access-from-files --window-size=1280,800 --screenshot=out.png file:///<work>/shot1-popup.html
```

# Pinterest setup guide

This guide connects Pinterest, so NEFORUM creates **Pins on one of your boards**, automatically with your own API keys or by hand-off. Every Pin needs an image or a video; NEFORUM uses your text as the Pin **description**, your post title as the Pin **title**, and your post link as the page the Pin **links to**.

## Steps

These steps set up "Your own API keys". Read *Before you start* below first: Pinterest must approve your app, and until it grants Standard access NEFORUM can only make **test Pins** in Pinterest's API Sandbox, which only you can see. Do the NEFORUM part on Windows or macOS: Pinterest cannot send you back to a phone after you sign in.

1. Use a business account.
   - If your Pinterest account is personal, open Pinterest **Settings > Account management** and choose **Convert to a business account**. It is free and keeps your profile, Pins and followers. Pinterest no longer shows developer apps that belong to personal accounts.
2. Open <https://developers.pinterest.com/apps/> while signed in.
3. Click **Connect app** (or **Create app**).
4. Fill in the request form:
   - **App name**: anything, e.g. `NEFORUM for Ada`.
   - **Description**: e.g. "Personal cross-posting: I create Pins on my own boards from the NEFORUM app."
   - **Website** and **privacy policy**: a page you control. Your profile page or a short page on GitHub is fine.
5. Under **Redirect URIs**, add this address exactly as written:

   ```
   http://localhost:52771/callback
   ```

   - Add it now. Pinterest locks redirect URIs while it reviews the app.
   - Use `http`, not `https`. Pinterest's form accepts `https`, an app's own scheme, or `http` with `localhost`, and NEFORUM listens on `http`. An `https://...` address never matches what NEFORUM sends.
   - Use `localhost`, not `127.0.0.1`. Pinterest accepts `http` only with `localhost`.
   - Pinterest compares the address character for character: `http`, `localhost`, port `52771`, path `/callback`, no trailing slash. A mismatch ends the sign-in with "The provided redirect URI does not match the registered URI".
6. Submit the form.
7. Wait until the app card shows **Trial access**. Only then does Pinterest show the **App secret key**.
8. In NEFORUM, open **Accounts > Add account > Pinterest > Your own API keys**.
9. Fill in the form:
   - **App ID** and **App secret key**, both from the app's page at developers.pinterest.com. Click **Show key** to see the secret.
   - **Board**: the name of the board your Pins should go to, for example `Summer Recipes`. You can also paste its id or the board's web address. You can leave it empty if you have only one board. With Trial access NEFORUM makes this board in the sandbox if it is not there yet (named `NEFORUM` if you leave it empty).
   - **Access level of your app**: `trial` or `standard`, exactly as your app card shows it. With `trial`, NEFORUM signs in to Pinterest's API Sandbox and every Pin is a test Pin (see *Trial access: test Pins only*). With `standard`, Pins are public.
   - **Sandbox access token**: leave it empty to sign in through the browser. See *Steps: paste a sandbox token* for the other way.
   - **Redirect URI you registered**: keep `localhost`. Pick `127.0.0.1` only if your app already lists exactly `http://127.0.0.1:52771/callback`.
10. Click **Connect**. Your browser opens Pinterest.
11. Sign in if asked.
12. Allow every permission NEFORUM asks for:
    - see and edit your boards (`boards:read`, `boards:write`)
    - see and create Pins (`pins:read`, `pins:write`)
    - see your account (`user_accounts:read`)

    Pinterest refuses to create Pins without the board-editing permission.

## Steps: paste a sandbox token (Trial access, no browser)

1. On <https://developers.pinterest.com/apps/>, click **Manage** on your app.
2. Open the **Configure** tab and scroll to **Generate access token**.
3. Choose **Sandbox** as the environment and click **Generate token**.
4. In NEFORUM, open **Accounts > Add account > Pinterest > Your own API keys**.
5. Fill in **App ID**, **Board** and **Access level** `trial`, and paste the token into **Sandbox access token**. The App secret key is not needed.
6. Click **Connect**.
   - Paste the token the day you generate it: it lasts 30 days from then, and NEFORUM counts the 30 days from the moment you connect.
   - It cannot be renewed. NEFORUM warns you 14, 7, 3 and 1 days before it ends. Then generate a new one and reconnect.

## Steps: get Standard access (public Pins)

1. On <https://developers.pinterest.com/apps/>, click **Upgrade** on your app card.
2. Check the app details.
3. Upload a screen recording that shows NEFORUM sending you through the Pinterest sign-in and then creating a Pin.
4. Submit and wait.
   - Developers report waits of about 1 to 4 weeks, and rejections are common when the video does not show the sign-in.
5. Once you are approved, remove the Pinterest account in NEFORUM and add it again with **Access level** `standard`. Sandbox tokens do not work in production, so the account needs a new sign-in.
6. Raise the daily limit in NEFORUM's quota settings, because Standard allows 100 writes per minute.

## Steps: hand-off (you press Save)

1. In NEFORUM, open **Accounts > Add account > Pinterest > Hand-off**.
2. When you publish, NEFORUM copies the description to the clipboard and opens Pinterest (see *Hand-off* under *How it works*).
3. Add the image if it is not filled in, and paste the description.
4. Choose a board.
5. Press **Save**.

## Ways to connect

| Tier | What you need | Cost | Limits | Review (as of October 2026) |
|---|---|---|---|---|
| **Your own API keys** (automatic) | A Pinterest **business** account (converting is free) and your own Pinterest developer app | Free | **Trial access:** 300 new Pins (and other writes) per app per day, 1000 API calls per app per day, test Pins in the API Sandbox only, no video Pins. **Standard access:** 100 writes per minute | **Two reviews.** Pinterest must approve the app for **Trial access** before it works at all. With Trial access, **NEFORUM can only make test Pins that you alone can see**. To make public Pins you must pass a second review for **Standard access**, which needs a screen recording |
| **Hand-off** (you press Save) | Nothing | Free | None | None |

### Before you start

- **Trial access means test Pins only.** See the next section.
- **Approval can be slow.** Pinterest says it reviews Trial requests on business days. In 2025 and 2026 many developers reported waiting more than a week, and some were refused without a reason. While the app is waiting, the app secret is hidden and every API call fails. NEFORUM then shows "Your Pinterest developer app is not approved yet".
- **Every NEFORUM user needs their own app and their own approval.** NEFORUM is open source and has no central server, so it cannot share one approved app between users.

### Trial access: test Pins only

- Pinterest refuses Pins from Trial apps on its normal API with "Apps with Trial access may not create Pins in production ... use API Sandbox https://api-sandbox.pinterest.com instead" (error code 29).
- So with Access level `trial`, NEFORUM sends every call to the API Sandbox, `https://api-sandbox.pinterest.com/v5/`. Pinterest's sandbox page says the calls are the same as production, only the host changes.
- Sandbox Pins and boards are test entities. Pinterest's docs say that Pins and boards created with Trial access "are only visible to their creator". You see them on your own profile in the Pinterest app and on pinterest.com. Your followers never see them.
- Your production boards do not exist in the sandbox, so NEFORUM makes a sandbox board on the first sign-in.
- The sandbox cannot make video Pins. NEFORUM stops a video Pin before it is sent.
- Do not point a sandbox account at a group board: Pinterest says the board owner may get a notification.
- A sandbox token works only in the sandbox, and a production token only in production. Moving between them needs a new sign-in.
- An account added as Trial before NEFORUM 1.4.4 still signs in to production, where its Pins are refused with code 29. NEFORUM then offers **Reconnect and retry**, which signs in again to the sandbox and makes the sandbox board.
- The composer shows a reminder on every Trial account's post that its Pins are test Pins only you can see.
- **Public Pins need Standard access**: click **Upgrade** on your app card (see *Steps: get Standard access*).

## How it works

### What gets posted

| NEFORUM | Pinterest |
|---|---|
| Text (up to 800 characters) | Pin description. Hashtags stay as plain text |
| Title (up to 100 characters) | Pin title |
| Link | The page the Pin links to (up to 2048 characters) |
| 1 image | Image Pin (JPEG or PNG, up to 20 MB), with alt text up to 500 characters |
| 2 to 5 images | Carousel Pin |
| 1 video | Video Pin: MP4/M4V, 4 seconds to 5 minutes. NEFORUM uploads it, waits for Pinterest to process it and uses the frame at 1 second as the cover |

Pinterest recommends a 2:3 shape (1000 x 1500 px) for images and 9:16 for videos.

Advanced settings for each post (in the post's per-platform options):

- `pinterestBoardId`: post this Pin to a different board, by id.
- `pinterestBoardSectionId`: put the Pin in a section of the board.
- `pinterestCoverImageUrl`: a public image to use as the video cover.
- `pinterestCoverKeyFrameSeconds`: which second of the video to use as the cover (default 1).

### Staying signed in

- A Pinterest sign-in lasts **30 days**. NEFORUM renews it with Pinterest's refresh token when a post goes out and the last renewal is at least 7 days old.
- The refresh token itself lapses **60 days after the last renewal**, and every renewal starts a new 60 days. If you do not post to Pinterest for two months, you have to reconnect. Accounts shows the date.
- If Pinterest is briefly unavailable or rate limits the renewal, NEFORUM tries again later instead of asking you to reconnect.
- A Trial browser sign-in renews the same way, through the sandbox's token address (`https://api-sandbox.pinterest.com/v5/oauth/token`).
- A pasted sandbox token lasts **30 days** and is never renewed. Accounts shows its end date, and NEFORUM warns 14, 7, 3 and 1 days before it.

### Hand-off

NEFORUM copies the description to the clipboard and then does one of two things:

- If your image is already online (for example through a media host), it opens Pinterest's Pin builder at `https://www.pinterest.com/pin/create/button/` with the image, link and description filled in. Pinterest fills in only the first 500 characters of the description, and the title cannot be filled in this way.
- Otherwise, on a phone NEFORUM opens the share sheet with your image so you can choose **Pinterest**. On a computer, it opens Pinterest's Pin creation tool, <https://www.pinterest.com/pin-creation-tool/> (the old `/pin-builder/` address redirects there), so you can drag the image in after **Save media to Downloads**. The Pinterest app treats shared text as a link, so paste the description from the clipboard.

Then you choose a board and press **Save**.

## Limits

What the automatic tier **cannot** do:

- **Schedule on Pinterest's side.** The API has no "publish at" field (checked against the v5 OpenAPI description and the Create Pin reference on 2026-10-11). NEFORUM's own scheduler sends the Pin at the right time, so NEFORUM has to be running then. Pinterest's developer guidelines also require you to choose every Pin yourself. NEFORUM never creates Pins you did not write.
- **Post GIF or WebP images.** The API accepts uploaded images only as JPEG or PNG.
- **Post to secret boards.** NEFORUM only lists your public boards and group boards.
- **Set alt text on carousels.** Alt text is sent only for single-image Pins.
- **Connect from a phone.** Pinterest needs a web address to send you back to after you sign in. It does not document app links such as `neforum://callback`. Connect from NEFORUM on Windows or macOS. On phones, use the hand-off tier.
- **Make public Pins or video Pins with Trial access.** Trial apps work only in the API Sandbox.

### Known limitations

- Pinterest's redirect form accepts `http` only with `localhost`, so `http://127.0.0.1:52771/callback` is likely refused there. NEFORUM uses `localhost` by default and keeps the `127.0.0.1` choice only for apps that already list that address.
- NEFORUM renews a Trial browser sign-in at the sandbox's token address. Pinterest's sandbox page says such a token can be refreshed for long-term testing but shows the renewal request only for production. Not yet confirmed with a live sandbox renewal.
- A pasted sandbox token's 30 days run from when Pinterest made it. Pinterest gives no way to read that date, so NEFORUM counts from the moment you connect.
- Pinterest community reports say a video Pin without a cover image fails with a confusing "unauthorized" error. NEFORUM sends a cover frame time (`cover_image_key_frame_time`). It is not confirmed that this is enough. If video Pins fail, set `pinterestCoverImageUrl`.
- NEFORUM counts description length in UTF-16 units. An emoji counts as 2, while Pinterest counts it as 1, so NEFORUM may stop you slightly before Pinterest's real limit.
- The Pinterest app's Android package (`com.pinterest`) and iOS link (`pinterest://`) used for hand-off are well known but not officially documented.

## Sources

- Pinterest API v5 OpenAPI description (v5.28.0): <https://raw.githubusercontent.com/pinterest/api-description/main/v5/openapi.json>
- Create Pin: <https://developers.pinterest.com/docs/api/v5/pins-create/>
- Authentication and token lifetimes: <https://developers.pinterest.com/docs/getting-started/set-up-authentication-and-authorization/>
- Connect app / redirect URI rules: <https://developers.pinterest.com/docs/getting-started/connect-app/>
- Access tiers (Trial vs Standard): <https://developers.pinterest.com/docs/key-concepts/access-tiers/>
- API Sandbox (host, visibility, sandbox tokens, no video Pins): <https://developers.pinterest.com/docs/developer-tools/sandbox/>
- Rate limits: <https://developers.pinterest.com/docs/reference/rate-limits/>
- Save button (hand-off URL): <https://developers.pinterest.com/docs/web-features/buttons/>
- Developer guidelines: <https://policy.pinterest.com/en/developer-guidelines>
- Pin specs (Help Center): <https://help.pinterest.com/article/review-pin-specs>
- Official quickstart (localhost redirect): <https://github.com/pinterest/api-quickstart>
- Known issue, Trial access pending or denied: <https://community.pinterest.biz/t/known-issue-support-for-trial-access-pending-or-denied-access/50249>

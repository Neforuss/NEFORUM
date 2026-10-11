# Pinterest

NEFORUM can create **Pins on one of your boards**. Every Pin needs an image or a video. NEFORUM uses your text as the Pin **description**, your post title as the Pin **title**, and your post link as the page the Pin **links to**.

You can connect Pinterest in two ways:

| Tier | What you need | Cost | Limits | Review (as of October 2026) |
|---|---|---|---|---|
| **Your own API keys** (automatic) | A Pinterest **business** account (converting is free) and your own Pinterest developer app | Free | **Trial access:** 300 new Pins (and other writes) per app per day, 1000 API calls per app per day. **Standard access:** 100 writes per minute | **Two reviews.** Pinterest must approve the app for **Trial access** before it works at all. With Trial access, **your Pins are only visible to you**. To make them public you must pass a second review for **Standard access**, which needs a screen recording |
| **Hand-off** (you press Save) | Nothing | Free | None | None |

**Be aware before you start:**

- **Trial access keeps your Pins private.** Pinterest's own docs say that all Pins and boards created with Trial access are "only visible to their creator". Your followers will not see them until your app has Standard access.
- **Approval can be slow.** Pinterest says it reviews Trial requests on business days. In 2025 and 2026 many developers reported waiting more than a week, and some were refused without a reason. While the app is waiting, the app secret is hidden and every API call fails. NEFORUM then shows "Your Pinterest developer app is not approved yet".
- **Every NEFORUM user needs their own app and their own approval.** NEFORUM is open source and has no central server, so it cannot share one approved app between users.

What the automatic tier **cannot** do:

- **Schedule on Pinterest's side.** The API has no "publish at" field. NEFORUM's own scheduler sends the Pin at the right time, so NEFORUM has to be running then. Pinterest's developer guidelines also require you to choose every Pin yourself. NEFORUM never creates Pins you did not write.
- **Post GIF or WebP images.** The API accepts uploaded images only as JPEG or PNG.
- **Post to secret boards.** NEFORUM only lists your public boards and group boards.
- **Set alt text on carousels.** Alt text is sent only for single-image Pins.
- **Connect from a phone.** Pinterest needs a web address to send you back to after you sign in. It does not document app links such as `neforum://callback`. Connect from NEFORUM on Windows or macOS. On phones, use the hand-off tier.

## Set up "Your own API keys"

1. **Use a business account.** If your Pinterest account is personal, open Pinterest **Settings > Account management** and choose **Convert to a business account**. It is free and keeps your profile, Pins and followers. Pinterest no longer shows developer apps that belong to personal accounts.
2. Open <https://developers.pinterest.com/apps/> while signed in and click **Connect app** (or **Create app**).
3. Fill in the request form:
   - **App name**: anything, e.g. `NEFORUM for Ada`.
   - **Description**: e.g. "Personal cross-posting: I create Pins on my own boards from the NEFORUM app."
   - **Website** and **privacy policy**: a page you control. Your profile page or a short page on GitHub is fine.
4. Under **Redirect URIs**, add **both** of these addresses exactly as written:

   ```
   http://localhost:52771/callback
   http://127.0.0.1:52771/callback
   ```

   Add them now. Pinterest locks redirect URIs while it reviews the app. Pinterest compares them character for character: `http`, port `52771`, path `/callback`, no trailing slash.
5. Submit the form and wait until the app card shows **Trial access**. Only then does Pinterest show the **App secret key**.
6. In NEFORUM, open **Accounts > Add account > Pinterest > Your own API keys** and fill in:
   - **App ID** and **App secret key**, both from the app's page at developers.pinterest.com. Click **Show key** to see the secret.
   - **Board**: the name of the board your Pins should go to, for example `Summer Recipes`. You can also paste its id or the board's web address. You can leave it empty if you have only one board.
   - **Access level of your app**: `trial` or `standard`, as shown on your app card. This only controls a reminder in the composer.
   - **Redirect URI you registered**: keep `localhost` unless you registered only the `127.0.0.1` address.
7. Click **Connect**. Your browser opens Pinterest. Sign in if asked, then allow every permission NEFORUM asks for:
   - see and edit your boards (`boards:read`, `boards:write`)
   - see and create Pins (`pins:read`, `pins:write`)
   - see your account (`user_accounts:read`)

   Pinterest refuses to create Pins without the board-editing permission.

### Get Standard access (public Pins)

1. On <https://developers.pinterest.com/apps/>, click **Upgrade** on your app card.
2. Check the app details. Upload a screen recording that shows NEFORUM sending you through the Pinterest sign-in and then creating a Pin.
3. Submit and wait. Developers report waits of about 1 to 4 weeks, and rejections are common when the video does not show the sign-in. Once you are approved, change **Access level** to `standard` by reconnecting the account. Then raise the daily limit in NEFORUM's quota settings, because Standard allows 100 writes per minute.

### Staying signed in

- A Pinterest sign-in lasts **30 days**. NEFORUM renews it automatically when it is close to expiring, using Pinterest's refresh token.
- The refresh token itself lapses after **60 days without use**. Every renewal starts a new 60 days. If you do not use NEFORUM for Pinterest for two months, you have to reconnect.

## What gets posted

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

## Hand-off

NEFORUM copies the description to the clipboard and then does one of two things:

- If your image is already online (for example through a media host), it opens Pinterest's Pin builder at `https://www.pinterest.com/pin/create/button/` with the image, link and description filled in. Pinterest fills in only the first 500 characters of the description, and the title cannot be filled in this way.
- Otherwise, on a phone NEFORUM opens the share sheet with your image so you can choose **Pinterest**. On a computer, it opens <https://www.pinterest.com/pin-builder/> so you can upload the image yourself. The Pinterest app treats shared text as a link, so paste the description from the clipboard.

Then you choose a board and press **Save**.

## Known limitations

- The `127.0.0.1` redirect address has not been confirmed for Pinterest. Pinterest's own sample app uses `localhost`, which is why NEFORUM uses `localhost` by default and asks you to register both addresses.
- Pinterest community reports say a video Pin without a cover image fails with a confusing "unauthorized" error. NEFORUM sends a cover frame time (`cover_image_key_frame_time`). It is not confirmed that this is enough. If video Pins fail, set `pinterestCoverImageUrl`.
- NEFORUM counts description length in UTF-16 units. An emoji counts as 2, while Pinterest counts it as 1, so NEFORUM may stop you slightly before Pinterest's real limit.
- The Pinterest app's Android package (`com.pinterest`) and iOS link (`pinterest://`) used for hand-off are well known but not officially documented.

## Sources

- Pinterest API v5 OpenAPI description (v5.28.0): <https://raw.githubusercontent.com/pinterest/api-description/main/v5/openapi.json>
- Create Pin: <https://developers.pinterest.com/docs/api/v5/pins-create/>
- Authentication and token lifetimes: <https://developers.pinterest.com/docs/getting-started/set-up-authentication-and-authorization/>
- Connect app / redirect URI rules: <https://developers.pinterest.com/docs/getting-started/connect-app/>
- Access tiers (Trial vs Standard): <https://developers.pinterest.com/docs/key-concepts/access-tiers/>
- Rate limits: <https://developers.pinterest.com/docs/reference/rate-limits/>
- Save button (hand-off URL): <https://developers.pinterest.com/docs/web-features/buttons/>
- Developer guidelines: <https://policy.pinterest.com/en/developer-guidelines>
- Pin specs (Help Center): <https://help.pinterest.com/article/review-pin-specs>
- Official quickstart (localhost redirect): <https://github.com/pinterest/api-quickstart>
- Known issue, Trial access pending or denied: <https://community.pinterest.biz/t/known-issue-support-for-trial-access-pending-or-denied-access/50249>

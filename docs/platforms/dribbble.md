# Dribbble setup guide

This guide sets up Dribbble. By default NEFORUM hands each shot to Dribbble's uploader and you press **Publish**; with your own Dribbble app it can also create shots by itself, for still images of 800 x 600 pixels.

## Steps

1. In NEFORUM, go to **Accounts > Add > Dribbble > Hand-off (share sheet)**.
2. Click **Connect**. Nothing is signed in.
3. Publish a post with Dribbble selected.
4. Follow the numbered steps in the hand-off window.
   - NEFORUM opens the uploader (`https://dribbble.com/uploads/new`), puts the description on the clipboard and lists the title and tags to copy.
   - With the NEFORUM browser extension on a computer, the uploader is filled in for you. See [Browser extension](../browser-extension.md).
   - Otherwise, save the images with **Save media to Downloads** and drop them on the page, add a **Text** block for the description, click **Continue**, add the tags in **Final Touches** and press **Publish**.

## Steps: post automatically with your own app

1. Sign in to Dribbble and open <https://dribbble.com/account/applications/new>.
2. Fill in a name (for example `NEFORUM for Ada`), a description and a website.
3. As **Callback URL**, enter exactly:

   ```
   http://127.0.0.1:52771/callback
   ```

4. Register the application.
5. Copy the **Client ID** and the **Client Secret**.
6. In NEFORUM, go to **Accounts > Add > Dribbble > Your own API keys**.
7. Paste both values.
8. Click **Connect**.
9. In the browser window that opens, allow access.
   - NEFORUM asks for `public` (read your profile) and `upload` (create shots).

## How it works

Dribbble only receives posts marked as artwork, with at least one image (or, by hand-off, a video).

**Hand-off** uses Dribbble's own uploader, which takes everything the website takes: several images, a video, text blocks and full-size work. Choose who publishes under **Publish as** (you or a team), then **Continue** opens **Final Touches** for the thumbnail and the tags.

**Your own app** uses Dribbble's API v2 (`POST /v2/shots`), which is stricter than the website:

- One image per shot, **exactly 800 x 600 or 400 x 300 pixels**, PNG, JPG or GIF, up to 8 MB. NEFORUM fits photos to 4:3 (borders or cropping, as set under photo fitting in Settings) and resizes them to 800 x 600. GIFs are never changed, so a GIF must already have one of the two sizes.
- No video. For video, multi-image shots or large work, use the hand-off.

What goes where:

| NEFORUM | Dribbble |
|---|---|
| Title (or the first line of the text) | Shot title |
| Text | Description |
| Tags | Tags, the first 12 |
| Rating: adult | Not posted: Dribbble does not accept adult work |
| Rating: mature | Posted with a warning: Dribbble's guidelines leave no room for mature work |
| Made with AI | A reminder: Dribbble refuses work made entirely with AI, so say in the description how AI helped |

Dribbble has no field for "Ask not to train AI".

NEFORUM uses the Client Secret once, to sign in, and does not keep it. Dribbble's sign-in does not expire.

Dribbble answers a new shot with "accepted" while it processes the image; the shot appears on your profile shortly after.

## Limits

- **API rate limit**: 60 requests a minute and 1,440 a day per user. A shot uses one.
- **Account status**: creating a shot needs a "player" or a team. Shots from a basic (Limited) account stay visible only on your own profile until Dribbble approves you as a free Designer account. When you connect, NEFORUM notes whether Dribbble lets the account upload yet.
- **Review**: every published shot goes through Dribbble's human Shot Review.
- **Website uploads**: PNG, JPG or GIF images up to 10 MB, MOV or MP4 video up to 20 MB; at least 1600 pixels wide is recommended. NEFORUM hands over up to 10 files per shot.
- **Older upload caps**: Dribbble's 2015 changelog named 5 shots a day and 48 a month. This may be out of date.
- **Shot guidelines**: digital design only; no photography, watermarks, unaltered stock, work made entirely with AI, promotional or tutorial videos, or contact details in descriptions.
- **API terms**: Dribbble can refuse API access at any time. Apps may act for users only when the user asks, which includes posting at a time the user picked.

## Troubleshooting

- **"Dribbble does not let this account upload shots yet"** (HTTP 403): the account is not a player or a team member yet. Apply for a Designer account on Dribbble, or use the hand-off.
- **"Dribbble's API takes exactly 800 x 600 or 400 x 300 pixels"**: turn on photo fitting in Settings, resize the GIF, or use the hand-off.
- **"Dribbble refused the return address"**: the Callback URL of your app must be exactly the address NEFORUM asks for. If your app uses `http://localhost:52771/callback`, enter that in **Redirect URI (advanced)**.
- **Rate limited**: NEFORUM waits and tries again later.

## Sources

- API v2 overview and rate limits: <https://developer.dribbble.com/v2/>
- OAuth (authorize, token, scopes `public` and `upload`): <https://developer.dribbble.com/v2/oauth/>
- Shots (image sizes, 8 MB, 12 tags, 202 with `Location`, player or team): <https://developer.dribbble.com/v2/shots/>
- User (`can_upload_shot`): <https://developer.dribbble.com/v2/user/>
- API terms: <https://developer.dribbble.com/terms/>
- Upload caps (2015): <https://developer.dribbble.com/changes/2015-02-18-can-upload-shot/>
- Creating shots on the website: <https://help.dribbble.com/en/articles/11062601-creating-dribbble-shots>
- Designer accounts: <https://help.dribbble.com/en/articles/11056171-designer-accounts>
- Shot Review: <https://help.dribbble.com/en/articles/11123194-shot-review-process>
- Shot guidelines: <https://help.dribbble.com/en/articles/11056039-dribbble-shot-guidelines>

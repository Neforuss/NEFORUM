# DeviantArt setup guide

This guide connects DeviantArt through your own free DeviantArt app, so NEFORUM publishes your artwork as deviations by itself. Without an app, NEFORUM hands each post to DeviantArt's submit page instead.

## Steps

1. Sign in to DeviantArt in your browser and open <https://www.deviantart.com/developers/register>.
2. Give the app a name, for example `NEFORUM for Ada`.
3. Choose the client type **Public**.
   - A Public app has no secret: NEFORUM signs in with PKCE instead.
4. Under **OAuth2 Redirect URI Whitelist**, enter exactly:

   ```
   http://127.0.0.1:52771/callback
   ```

   - This one address works on every device: phones and Macs pass it on to NEFORUM by themselves.
5. Save the app.
   - You find it again at <https://www.deviantart.com/studio/apps>.
6. Copy the app's **client_id**.
7. In NEFORUM, go to **Accounts > Add > DeviantArt > Your own API keys**.
8. Paste the client_id into **Client ID** and leave **Client secret** empty.
9. Click **Connect**.
10. In the browser window that opens, allow access.
    - NEFORUM asks for `basic` and `user` (read your username), `stash` (put a file in your Sta.sh) and `publish` (publish it).

## Steps: post by hand-off

1. In NEFORUM, go to **Accounts > Add > DeviantArt > Hand-off (share sheet)**.
2. Click **Connect**. Nothing is signed in.
3. Publish a post with DeviantArt selected.
4. Follow the numbered steps in the hand-off window.
   - On a computer, NEFORUM opens the submit page (`https://www.deviantart.com/studio?new=1`), puts the description on the clipboard and lists the title and tags to copy. Save the images with **Save media to Downloads** and pick them on the page.
   - On a phone, NEFORUM shares the images to the DeviantArt app.
   - Set the rating, **Created using AI tools** and **NoAI** as the steps say, then press **Submit**.

## How it works

DeviantArt only receives posts marked as artwork, with at least one image.

Publishing takes two calls to DeviantArt's API:

1. **Sta.sh submit** puts the image in your Sta.sh, DeviantArt's private staging area, with the title, description, tags and AI labels.
2. **Sta.sh publish** turns that draft into a deviation and sets the rating.

What goes where:

| NEFORUM | DeviantArt |
|---|---|
| Title (or the first line of the text) | Title, up to 50 characters, the length DeviantArt's submit form takes. NEFORUM asks you to shorten a longer title |
| Text | Description (artist comments), with its line breaks |
| Tags | Tags. DeviantArt takes letters, digits and underscores only, so NEFORUM drops other characters (`oil-painting` becomes `oilpainting`) |
| Rating: general | Not mature |
| Rating: mature | Mature, level **Moderate** |
| Rating: adult | Mature, level **Strict** |
| Made with AI | Created using AI tools (`is_ai_generated`) |
| Ask not to train AI | NoAI (`noai`). DeviantArt opts every deviation out of AI datasets by default |

The sign-in lasts an hour and NEFORUM renews it by itself. The renewal key lasts 3 months: if NEFORUM does not post to DeviantArt for 3 months, click **Reconnect** once. DeviantArt hands out a new renewal key at every renewal, so an account copied to a second device stays connected on only one of them.

Your client secret, if your app is Confidential, stays in this device's secure storage.

## Limits

- **One image per deviation** through the API. On the website (hand-off), a deviation holds up to 10 images, or 100 with a Core membership.
- **No fixed quota.** DeviantArt slows down apps that send too many requests (HTTP 429); NEFORUM tries again later.
- **Verified email.** DeviantArt refuses posts from accounts whose email address is not verified.
- **File types and sizes**: DeviantArt's API documentation lists none. NEFORUM sends JPEG, PNG and GIF and turns other photos into JPEGs.
- **API License Agreement**: the API is free, but DeviantArt may add fees with 60 days' notice, and either side may end the agreement with 30 days' notice.

## Troubleshooting

- **"DeviantArt refused the return address"**: the redirect URI in your app's whitelist must match exactly, character for character. If you whitelisted `http://localhost:52771/callback` instead, enter that address in **Redirect URI (advanced)**.
- **"Verify your email address first"**: DeviantArt answered `unverified_account`. Verify the address on deviantart.com, then publish again.
- **"Accept DeviantArt's submission policy" or "terms of service"**: DeviantArt answered with error code 0 or 1. Submit one deviation on deviantart.com yourself, then publish again.
- **Publishing failed after the upload**: the image waits in your Sta.sh as a draft. Publish it there, or retry in NEFORUM (which uploads it again).
- **"DeviantArt refused the sign-in"**: click **Reconnect** on the account.

## Sources

- The signed-in user (`user/whoami`, scopes `basic` and `user`): <https://deviantart.readme.io/reference/user_whoami.md>
- Sta.sh submit (fields `file`, `title`, `artist_comments`, `tags[]`, `is_ai_generated`, `noai`): <https://deviantart.readme.io/reference/stash_submit.md>
- Sta.sh publish (`itemid`, `is_mature`, `mature_level` strict or moderate, error codes 0 to 9): <https://deviantart.readme.io/reference/stash_publish.md>
- Authentication (Public and Confidential clients, PKCE, token lifetimes, exact redirect URIs): <https://deviantart.readme.io/docs/authentication.md>
- Getting started (User-Agent and compression required): <https://deviantart.readme.io/docs/getting-started.md>
- Errors and rate limiting: <https://deviantart.readme.io/docs/errors.md>
- API License Agreement: <https://www.deviantart.com/about/policy/api/>
- Multi-image deviations: <https://www.deviantart.com/team/journal/Extend-your-creativity-with-multi-image-deviations-1127107538>
- NoAI by default: <https://www.deviantart.com/team/journal/A-New-Standard-for-Opting-Out-of-AI-Datasets-934500371>

# Inkbunny setup guide

This guide connects Inkbunny, so NEFORUM uploads your artwork and fills in the submission by itself. It needs your username and password only once, and no developer account.

## Steps

1. Sign in on inkbunny.net and open your **Account Settings**.
2. Tick **Enable API Access** and save.
   - If you set an **Allowed IP Range** there, the device NEFORUM runs on must be inside it.
3. In NEFORUM, go to **Accounts > Add > Inkbunny > Open API**.
4. Enter your Inkbunny username and password.
5. Click **Connect**.

## Steps: post by hand-off

1. In NEFORUM, go to **Accounts > Add > Inkbunny > Hand-off (share sheet)**.
2. Click **Connect**. Nothing is signed in.
3. Publish a post with Inkbunny selected.
4. Follow the numbered steps in the hand-off window.
   - NEFORUM opens inkbunny.net, puts the description on the clipboard and lists the title and keywords to copy. Start a new submission with Inkbunny's upload wizard, save the files with **Save media to Downloads** and pick them there.
   - Tick the content ratings as the steps say, then submit.

## How it works

Inkbunny only receives posts marked as artwork, with at least one image.

**Signing in**: NEFORUM sends your username and password to Inkbunny once (in the body of the request, never in the address) and gets a session back. It keeps only that session, in this device's secure storage, and forgets the password. Removing the account signs the session out.

**Publishing** takes two calls:

1. `api_upload.php` uploads every file into one new submission, which is not public yet.
2. `api_editsubmission.php` fills in the details and makes it public.

What goes where:

| NEFORUM | Inkbunny |
|---|---|
| Title (or the first line of the text) | Title |
| Text | Description |
| Tags | Keywords |
| Visibility: public | Public |
| Visibility: unlisted | Public, without notifying your watchers |
| Visibility: followers | Friends only |
| Visibility: private | Not public (the submission stays hidden) |
| Rating: general | No content ratings |
| Rating: mature | Content rating **Nudity** |
| Rating: adult | Content rating **Sexual Themes** |

Inkbunny allows adult work, so every rating is accepted. It has no fields for "Made with AI" or "Ask not to train AI": say so in the description or the keywords.

The finished submission is at `https://inkbunny.net/s/<number>`.

## Limits

- **Keywords**: Inkbunny wants at least 4 (the minimum the PostyBirb cross-poster checks), so NEFORUM stops a post with fewer.
- **Files**: pictures (JPEG, PNG or GIF), Flash (SWF), video (FLV or MP4), audio (MP3) and writing (DOC, RTF or TXT). NEFORUM sends pictures, up to 20 in one submission, or one MP4 video. Inkbunny publishes no per-file limit.
- **Hourly limit**: Inkbunny limits how many submissions an account makes per hour. NEFORUM tries again later.
- **New accounts** may be hidden from search until an automated trust check passes.
- **Scripts**: Inkbunny asks external programs to use its API, never to read its pages.

## Troubleshooting

- **"Inkbunny did not sign you in"**: check the username and password, that **Enable API Access** is ticked, and that this device is inside your Allowed IP Range if you set one.
- **"Inkbunny ended the sign-in"**: the session is no longer valid (for example after you signed out everywhere). Click **Reconnect** on the account.
- **"Your files are uploaded as submission ..., which stays hidden"**: the details step failed after the upload. Finish the submission on inkbunny.net at the address in the message; retrying in NEFORUM would upload the files again.

## Sources

- Inkbunny API (login, upload, edit submission, error codes): <https://wiki.inkbunny.net/wiki/API>
- Field mapping and keyword minimum used by the PostyBirb cross-poster (third party): <https://raw.githubusercontent.com/mvdicarlo/postybirb/main/apps/client-server/src/app/websites/implementations/inkbunny/inkbunny.website.ts>

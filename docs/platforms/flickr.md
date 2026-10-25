# Flickr setup guide

This guide sets up Flickr. By default NEFORUM hands your photos to Flickr's uploader and you press **Upload**; with your own Flickr API key, which needs Flickr Pro, it uploads them by itself.

## Steps

1. In NEFORUM, go to **Accounts > Add > Flickr > Hand-off (share sheet)**.
2. Click **Connect**. Nothing is signed in.
3. Publish a post with Flickr selected.
4. Follow the numbered steps in the hand-off window.
   - On a computer, NEFORUM opens the uploader (`https://www.flickr.com/photos/upload/`), puts the description on the clipboard and lists the title and tags to copy. With the NEFORUM browser extension, the uploader is filled in for you (see [Browser extension](../browser-extension.md)).
   - On a phone, NEFORUM shares the photos to the Flickr app.
   - Set the content type and the safety level as the steps say, then click **Upload**.

## Steps: upload automatically with your own API key

1. Subscribe to Flickr Pro if you do not have it: only Pro members can request API keys.
2. Signed in to Flickr, open <https://www.flickr.com/services/apps/create/>.
3. Apply for a **non-commercial** key and describe your use, for example "posting my own photos and art from my NEFORUM app".
4. Wait until Flickr issues the key. Flickr reviews each application.
5. Open your app at <https://www.flickr.com/services/apps/by/me> and copy the **Key** and the **Secret**.
6. In NEFORUM, go to **Accounts > Add > Flickr > Your own API keys**.
7. Paste both values.
8. Click **Connect**.
9. In the browser window that opens, allow NEFORUM to access your account.
   - NEFORUM asks for `write`: upload photos.

## How it works

Flickr only receives posts marked as artwork, with at least one image or video.

Signing in uses OAuth 1.0a: NEFORUM gets a temporary token, you allow it on Flickr's authorization page, and NEFORUM swaps the temporary token for your own. That token never expires and never changes, so the account stays connected on every device you copy it to.

Each file is uploaded on its own (`https://up.flickr.com/services/upload/`) and becomes its own Flickr photo; the files of one post share the title, description and tags.

What goes where:

| NEFORUM | Flickr |
|---|---|
| Title (or the first line of the text) | Title |
| Text | Description |
| Tags | Tags (separated by spaces) |
| Visibility: public | Public |
| Visibility: unlisted | Public, but hidden from Flickr's public search |
| Visibility: followers | Friends and family |
| Visibility: private | Only you |
| Rating: general | Safety level **Safe** |
| Rating: mature | Safety level **Moderate** |
| Rating: adult | Safety level **Restricted** |
| Artwork | Content type "other" (art, illustration) |

Flickr has no fields for "Made with AI" or "Ask not to train AI". NEFORUM does not add photos to albums or groups (Flickr does that through separate API methods).

Your Key, Secret and token stay in this device's secure storage.

## Limits

- **API key**: only Flickr Pro members can request one, Flickr reviews each application and watches how keys are used, and each key gets one app page. Commercial use needs Flickr's permission.
- **Files**: JPEG, PNG, non-animated GIF, TIFF or BMP (Flickr turns TIFF and BMP into JPEG), up to 200 MB per photo and no wider than 31.25:1. RAW files are not supported. Video up to 1 GB, 1080p. NEFORUM takes up to 10 files per post.
- **Free accounts** can hold at most 50 non-public items, and are commonly said to be limited to 1,000 photos and videos in all (a third-party figure).

## Troubleshooting

- **"Flickr did not accept the Key and Secret"**: copy both again from <https://www.flickr.com/services/apps/by/me>. Every request is signed with the current time, so also check that this device's date and time are right.
- **"Flickr says NEFORUM may not upload for you"**: reconnect and allow access on Flickr's page.
- **"reached its upload limit"**: your Flickr account has no room for more uploads.
- **"File 2 of 3 failed"**: the files before it are already on Flickr. Upload the rest yourself, so nothing appears twice.

## Sources

- Flickr API help: <https://www.flickrhelp.com/hc/en-us/articles/4404070036884-Flickr-API>
- Upload API (fields, safety levels, content types, hidden): <https://www.flickr.com/services/api/upload.api.html>
- Upload requirements (types, sizes): <https://www.flickrhelp.com/hc/en-us/articles/4404079649300-Flickr-upload-requirements>
- API keys (Pro only, review): <https://www.flickr.com/services/api/misc.api_keys.html>
- Free account item limit (third party): <https://www.multcloud.com/tutorials/flickr-upload-limit-1003.html>

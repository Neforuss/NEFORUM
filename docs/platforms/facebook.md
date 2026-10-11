# Facebook in NEFORUM

*Last checked against Meta's developer docs on 11 October 2026. NEFORUM calls Graph API v25.0; the reference pages
now show v26.0, and v25.0 stays supported for about two years after its release.*

## What works, in one paragraph

NEFORUM can post automatically **only to Facebook Pages you manage**. Meta took away API posting to
**personal profiles** in 2018 (`publish_actions` was removed) and removed the **Groups API** in April 2024.
No app, NEFORUM included, can post to your own timeline or to a group for you. For those, NEFORUM has a
**hand-off** mode: it copies your text, opens Facebook, and you tap **Post** yourself.

## Tiers

| Tier | Works for | What you need | Cost | Limits |
|---|---|---|---|---|
| **Hand-off** (default) | Personal profiles and Pages | Nothing. The Facebook app, or a browser where you are logged in | Free | You paste the text and tap Post yourself. Facebook never lets another app fill in your text. |
| **Your own API keys** | Pages only | A Facebook account with a Page role that can create content, plus a free Meta developer app that you create and are admin of | Free (no paid Graph API tier) | Pages API budget: 4,800 calls x the number of people who engaged with the Page per rolling 24 h. No App Review is needed as long as only you (an app role user) log in. |

### Review status (October 2026)

* People who have a **role on the app** (admin, developer, tester) automatically get *Standard Access* to all
  `pages_*` permissions. They need no App Review and no Business Verification.
* If **anyone else** should use your app, Meta requires *Advanced Access*. That means Business Verification
  plus per-permission App Review (a screencast, a privacy policy and a data-deletion callback; developers
  report waiting 2 to 4+ weeks). NEFORUM does not need this, because each person brings their own app.
* **Visibility trap:** Meta's docs say data created while an app is in **Development mode**, such as
  test posts, "can only be seen by role users". If your app has a Development/Live switch, set it to **Live**.
  To do that, fill in a Privacy Policy URL, Terms URL, icon, category and contact email under
  *App settings > Basic*. Going Live needs no App Review. Business-type apps have no mode switch and use
  access levels only.

## Set up "Your own API keys"

1. Go to <https://developers.facebook.com/apps> and click **Create app**.
2. Choose the use case **Manage everything on your Page**, or the app type **Business**. If Meta asks for a
   business portfolio, pick the one that owns your Page (you can also skip this when the Page is not in a portfolio).
3. Under the use case, click **Customize** and make sure these permissions are added:
   `pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `business_management`.
   NEFORUM asks for exactly these by default. (`pages_manage_posts` needs the other two to work.)
4. Open **Facebook Login (for Business) > Settings** and:
   * switch on **Client OAuth login** and **Web OAuth login**, plus **Embedded browser OAuth login** if it is shown;
   * add this exact address under **Valid OAuth Redirect URIs** (click the suggestion so it becomes a chip):
     ```
     https://www.facebook.com/connect/login_success.html
     ```
   * Do **not** register `http://127.0.0.1:52771/callback` or `neforum://callback`. Facebook Login only
     accepts registered HTTPS redirects, so NEFORUM uses the page that Facebook itself hosts for desktop apps.
5. Under **App settings > Basic**, copy the **App ID** and the **App Secret** (click *Show*). Fill in the
   fields required for Live mode and switch the app to **Live** if your app has that switch.
6. In NEFORUM: **Add account > Facebook > Your own API keys**. Paste the App ID and App Secret. You can also
   type the name or ID of the Page you want to post to.
7. Press **Connect**. Facebook opens in your browser:
   * log in and approve the permissions;
   * **select the Page(s)** NEFORUM may use (or "opt in to all current and future Pages");
   * you land on a nearly blank page that says *Success*. Copy the **whole address** from the address bar.
     It contains `#access_token=...`. Paste it into NEFORUM.
8. NEFORUM exchanges the token for a long-lived one (about 60 days) and fetches your Pages. It then stores
   the Page token, which does not expire. If you left the Page field empty, NEFORUM picks the first Page
   you can post to. All your Pages are listed in the account details; to switch, reconnect and type
   the other Page's name.

**Alternative without the browser step:** open the [Graph API Explorer](https://developers.facebook.com/tools/explorer).
Select *your* app, add the permissions above, click **Generate Access Token**, and paste the token into the
optional *User access token* field.

Everything stays on your device: the App Secret, the user token and the Page token are kept in NEFORUM's
secret store. NEFORUM also sends `appsecret_proof` with every call, so you can switch on
*App settings > Advanced > Require App Secret*.

## What NEFORUM posts

| Post | Graph call |
|---|---|
| Text, optionally with a link preview | `POST /{page-id}/feed` with `message` and `link` |
| One photo | `POST /{page-id}/photos`: multipart `source` upload with `caption` and `alt_text_custom`. No media host is needed. |
| 2 to 10 photos | each photo `POST /{page-id}/photos` with `published=false`, then `POST /{page-id}/feed` with `attached_media[n]={"media_fbid":"..."}` |
| One video | `POST /{page-id}/videos`: multipart `source` with `description` (and `title` if set) |
| Scheduled (when you let Facebook hold the schedule) | `published=false` + `scheduled_publish_time` on the same call. Multi-photo posts upload the photos with `published=false&temporary=true` and send `unpublished_content_type=SCHEDULED` on `/feed` (Page photos reference). |
| Taking a scheduled post back (you edit, reschedule, delete or "publish now") | `DELETE /{id}` with the Page token, where the id is the scheduled post (text, link and photo posts) or the video. A post that no longer exists (HTTP 404 or error 100/33) counts as removed. |

## Limits

* Text: 63,206 characters. Facebook does not document how it counts them; NEFORUM counts UTF-16 units.
  The feed shows *See more* after about 477 characters. Facebook has no threads, so long posts are not split.
* Photos: JPEG, PNG, GIF, BMP or TIFF, up to 10 MB each (keep PNGs under 1 MB to avoid pixelation). Up to
  10 per post in NEFORUM. Photos and video cannot be mixed in one post.
* Video: one per post, up to 1 GB and 20 minutes (the limit for non-resumable uploads).
* Photo posts cannot carry a link preview, so NEFORUM adds the link to the text.
* Scheduling on Facebook's side: Facebook needs at least 10 minutes' notice; NEFORUM hands a post over only when it
  is at least 15 minutes ahead, so that uploads and clock drift cannot push it under the minimum. Posts and photos
  up to 30 days ahead (the Pages API guide; the `/feed` reference says 75 days, so NEFORUM uses the safer 30), videos
  up to 180 days (the `/videos` reference says 6 months). Anything outside that window is kept and published by
  NEFORUM itself, which needs the device to be on at that time.

## Known limitations

* **No personal profiles, no groups** through the API (see above). Use hand-off.
* **Hand-off cannot prefill text.** Meta deprecated `sharer.php?quote=` (NEFORUM still sends it in case it
  is honoured). The Android app keeps only the URL from shared text, the iOS share sheet drops text, and
  Meta's developer policy forbids prefilling. NEFORUM always puts your text on the clipboard.
  On a phone with photos or a video, the share sheet attaches them for you. With a link, the share window
  opens. Otherwise facebook.com (or your Page address) opens.
* **Login paste step:** Facebook Login rejects loopback (`http://127.0.0.1`) and custom-scheme redirects
  for Live apps, so you copy the final address back by hand.
* **Reels** are not published yet (they need a separate 3-step upload; Meta caps them at 30 per Page per
  24 h). Videos are posted as regular Page videos.
* **Large videos** are sent in one request and held in memory. The resumable upload API (up to 1.75 GB and
  45 minutes) is not used yet.
* **Disconnecting** does not revoke anything at Facebook, because revoking would also break other Pages
  connected through the same app. To revoke, remove the app under Facebook *Settings > Apps and websites*.
* New Pages with little engagement have a very small API budget. Meta may also throttle Pages that post a
  lot without engagement (error 1390008, "posting too fast"). NEFORUM reports this as a quota error and can
  fall back to hand-off.
* Posts made through your app can only be edited or deleted by that same app.

## Sources

* Pages API, posts: <https://developers.facebook.com/docs/pages-api/posts>
* Page feed reference: <https://developers.facebook.com/docs/graph-api/reference/page/feed/>
* Page photos reference: <https://developers.facebook.com/docs/graph-api/reference/page/photos/>
* Page videos reference: <https://developers.facebook.com/docs/graph-api/reference/page/videos/>
* Video API overview: <https://developers.facebook.com/docs/video-api/overview>
* Video publishing guide: <https://developers.facebook.com/docs/video-api/guides/publishing>
* Manual login flow: <https://developers.facebook.com/docs/facebook-login/guides/advanced/manual-flow>
* Login security (Strict Mode, HTTPS): <https://developers.facebook.com/docs/facebook-login/security>
* Long-lived tokens: <https://developers.facebook.com/docs/facebook-login/guides/access-tokens/get-long-lived>
* Securing requests (appsecret_proof): <https://developers.facebook.com/docs/graph-api/securing-requests>
* Error handling: <https://developers.facebook.com/docs/graph-api/guides/error-handling>
* Rate limiting: <https://developers.facebook.com/docs/graph-api/overview/rate-limiting>
* Permissions: <https://developers.facebook.com/docs/permissions>
* Access levels: <https://developers.facebook.com/docs/graph-api/overview/access-levels>
* App modes: <https://developers.facebook.com/docs/development/build-and-test/app-modes>
* Business Verification: <https://developers.facebook.com/docs/development/release/business-verification>
* Graph API v19.0 changelog (Groups API removal): <https://developers.facebook.com/docs/graph-api/changelog/version19.0>
* Sharing on Android / iOS: <https://developers.facebook.com/docs/sharing/android>, <https://developers.facebook.com/docs/sharing/ios>
* Share button / sharer: <https://developers.facebook.com/docs/plugins/share-button>

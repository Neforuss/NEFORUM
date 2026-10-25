# LinkedIn setup guide

This guide connects **your own LinkedIn profile** to NEFORUM with a free LinkedIn developer app, so NEFORUM posts there automatically. Connect from NEFORUM on Windows or macOS; on phones, use the hand-off steps.

## Steps

1. Sign in to LinkedIn and open <https://www.linkedin.com/developers/apps>.
2. Click **Create app**.
3. Fill in:
   - **App name**: anything, e.g. `NEFORUM for Ada`.
   - **LinkedIn Page**: a company Page you administer. If you have none, create a free one at <https://www.linkedin.com/company/setup/new/> (a "company" with just your name is fine).
   - **App logo**: any square image.
4. Accept the API Terms of Use and click **Create app**.
5. On the app's **Settings** tab, click **Verify** next to the Page.
6. Open the verification link and approve it.
   - If you are the Page's admin, approval is instant. Otherwise the Page admin has 30 days to approve it.
7. Open the **Products** tab and click **Request access** for both of these. Both are approved immediately.
   - **Share on LinkedIn**
   - **Sign In with LinkedIn using OpenID Connect**
8. Open the **Auth** tab. Under **OAuth 2.0 settings > Authorized redirect URLs for your app**, click the pencil and add exactly

   ```
   http://127.0.0.1:52771/callback
   ```

   It must match exactly: `http`, `127.0.0.1`, port `52771`, path `/callback`, no trailing slash.
9. Click **Update**.
10. Still on the **Auth** tab, check that the **OAuth 2.0 scopes** list shows `openid`, `profile` and `w_member_social`.
11. Copy the **Client ID** and the **Primary Client Secret** (click the eye icon to reveal it).
12. In NEFORUM, choose **Add account > LinkedIn > Your own API keys** and paste both values.
13. Click **Sign in with LinkedIn**. Your browser opens LinkedIn's consent screen.
14. Click **Allow**. The browser comes back to NEFORUM.

## Steps: Hand-off without keys

1. In NEFORUM, add **LinkedIn**, choose **Hand off to the app** and click **Add LinkedIn**. Nothing else is needed.
2. Publish the post in NEFORUM. It copies your text to the clipboard and opens LinkedIn:
   - **Text only**: a new post, usually with your text already in it.
   - **With a link**: LinkedIn's share page for the link.
   - **With photos or video** (phones): the share sheet with your files. Pick LinkedIn.
3. Paste your text if it is missing (above the preview, for a link).
4. On a computer, attach photos or video yourself.
5. Press **Post**.

## How it works

| Tier | What you need | Cost | Limits | Review |
|---|---|---|---|---|
| **Your own API keys** (automatic) | A normal LinkedIn profile, a free LinkedIn developer app, and a LinkedIn company Page that you administer (needed only so the app can be created) | Free | About 150 API calls per member per day (resets at 00:00 UTC). A text post uses 1 call; each image uses 2 more; a video uses 3 or more | None. "Share on LinkedIn" and "Sign In with LinkedIn using OpenID Connect" are self-serve and approved instantly (as of October 2026) |
| **Hand-off** (you press Post) | Nothing | Free | None | None |

What the automatic tier **cannot** do:

- Post to **company Pages**. That needs LinkedIn's Community Management API, which LinkedIn only gives to registered companies after a review. NEFORUM does not support it.
- **Stay signed in for more than 60 days.** LinkedIn sign-ins expire after 60 days, and self-serve apps get no way to renew them automatically. NEFORUM will tell you to reconnect. Reconnecting takes one click if you are still signed in to linkedin.com.
- **Schedule on LinkedIn's side.** The API only publishes immediately. NEFORUM's own scheduler sends the post at the right time, so NEFORUM has to be running then, with a sign-in less than 60 days old.
- Read your posts, comments or statistics back.
- Mention people. Mentions need LinkedIn member IDs, and NEFORUM cannot look those up. `@` is shown as plain text. Hashtags such as `#flutter` work.
- Connect from a phone. LinkedIn only sends you back to a web address (not to an app). Connect LinkedIn from NEFORUM on Windows or macOS. On phones, use the hand-off tier.

The client secret and your sign-in token stay in NEFORUM's secret store on your device. Don't share the secret. Anyone who has it can act as your app.

### The "LinkedIn API version" field

LinkedIn releases a new API version every month (format `YYYYMM`). Each version keeps working for at least one year. NEFORUM defaults to `202609`. If a post ever fails with "LinkedIn no longer supports the API version", edit the account and enter a newer month, for example the current one. The current version is listed at <https://learn.microsoft.com/en-us/linkedin/marketing/versioning>.

### Don't change the permissions later

If your app ever asks LinkedIn for a different set of scopes, LinkedIn cancels every earlier sign-in for that app. NEFORUM always asks for `openid profile w_member_social`.

### Hand-off

- **Text only**: NEFORUM opens `https://www.linkedin.com/feed/?shareActive=true&text=…`, which usually opens a new post with your text already in it. This URL isn't documented by LinkedIn. Since October 2026 it sometimes opens the article editor instead. Your text is always copied to the clipboard as well: go to linkedin.com, click **Start a post** and paste.
- **With a link**: NEFORUM opens LinkedIn's official share page `https://www.linkedin.com/sharing/share-offsite/?url=…`. It only accepts the link, so paste your text above the preview.
- **With photos or video** (phones): NEFORUM opens the share sheet with your files and copies the text. Pick LinkedIn (Android package `com.linkedin.android`) and paste the text if it is missing. On iPhone, the LinkedIn app may accept only the text or link, not the images. On a computer, attach the files yourself.

## What gets posted

- **Text**: up to 3000 characters. LinkedIn treats `( ) [ ] { } < > @ | ~ _ * \ #` as formatting, so NEFORUM adds a backslash before each one to show it as written. A hashtag like `#word` is kept as a real hashtag. The backslashes may count toward the 3000-character limit, and NEFORUM warns you when that could matter.
- **Link without media**: posted as a link card. The API does not fetch the page preview the way the website does. NEFORUM sends the link, a title and an optional description:
  - The title is the post's title if you set one, otherwise the site name.
  - The description comes from the advanced field `linkDescription`.
  - The card has no thumbnail.
- **Link with media**: the link is added to the end of the text.
- **Images**: JPG, PNG or GIF (up to 250 frames), each under 36,152,320 pixels. One image, or 2–20 images as a multi-image post. Alt text is sent.
- **Video**: one MP4 per post, 3 seconds to 30 minutes, 75 KB to 500 MB. NEFORUM waits up to about 3 minutes for LinkedIn to process it, then publishes. The post title becomes the video title.
- **Images and video cannot be mixed** in one post.
- **Visibility**: Public → `PUBLIC`; Followers → `CONNECTIONS`. LinkedIn has no unlisted or private posts, so Unlisted becomes public and Private becomes connections-only. You can force `PUBLIC`, `CONNECTIONS` or `LOGGED_IN` with the advanced field `linkedinVisibility`.
- **Threads and content warnings** don't exist on LinkedIn.

## Limits

- Re-connect every 60 days (LinkedIn rule for self-serve apps).
- The 150 calls/day figure is documented for LinkedIn's older share API. LinkedIn doesn't publish a number for the current Posts API. Your real limit appears in the developer portal's **Analytics** tab after your first post that day.
- No company Pages, no mentions, no server-side scheduling, no link-preview thumbnails.
- Videos are held in memory while uploading, so very large videos need a device with enough free memory.
- Using a robot or automated browser on linkedin.com is against LinkedIn's User Agreement. NEFORUM uses only the official API and hand-off.

## Sources

- Share on LinkedIn (self-serve): <https://learn.microsoft.com/en-us/linkedin/consumer/integrations/self-serve/share-on-linkedin>
- Getting access / self-serve products: <https://learn.microsoft.com/en-us/linkedin/shared/authentication/getting-access>
- Authorization code flow (3-legged OAuth): <https://learn.microsoft.com/en-us/linkedin/shared/authentication/authorization-code-flow>
- Native client (PKCE) flow: <https://learn.microsoft.com/en-us/linkedin/shared/authentication/authorization-code-flow-native>
- Programmatic refresh tokens (partners only): <https://learn.microsoft.com/en-us/linkedin/shared/authentication/programmatic-refresh-tokens>
- Sign In with LinkedIn using OpenID Connect: <https://learn.microsoft.com/en-us/linkedin/consumer/integrations/self-serve/sign-in-with-linkedin-v2>
- Posts API: <https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/posts-api>
- little text format: <https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/little-text-format>
- Images API: <https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/images-api>
- Videos API: <https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/videos-api>
- MultiImage API: <https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/multiimage-post-api>
- API versioning: <https://learn.microsoft.com/en-us/linkedin/marketing/versioning>
- Rate limits: <https://learn.microsoft.com/en-us/linkedin/shared/api-guide/concepts/rate-limits>
- Share plugin (share-offsite): <https://learn.microsoft.com/en-us/linkedin/consumer/integrations/self-serve/plugins/share-plugin>
- Associate an app with a LinkedIn Page: <https://www.linkedin.com/help/linkedin/answer/a548360/associate-an-app-with-a-linkedin-page>
- Post length (3000 characters): <https://www.linkedin.com/help/linkedin/answer/a525301>

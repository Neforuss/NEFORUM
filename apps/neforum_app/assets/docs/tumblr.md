# Tumblr

NEFORUM can post to **any of your Tumblr blogs**, both your main blog and side blogs. You can connect it in two ways:

| Tier | What you need | Cost | Limits | Review |
|---|---|---|---|---|
| **Your own API keys** (automatic) | A normal Tumblr account and a free Tumblr app that you register yourself (takes about a minute) | Free. Tumblr's API has no paid tier | 250 new posts a day per Tumblr user, counted across all apps and the website. 250 image uploads, 20 videos and 60 minutes of video a day. Your app gets 1,000 API calls an hour and 5,000 a day. A post uses 1 call | None. A newly registered app can post, queue, draft and schedule straight away (as of October 2026) |
| **Hand-off** (you press Post) | Nothing | Free | The same daily limits, because you post yourself | None |

Tumblr's daily limits reset once per calendar day on Tumblr's server clock. Tumblr does not say which time zone that clock uses. When a limit is hit, NEFORUM shows "daily posting limit reached" and tries again later or offers the hand-off.

## What the automatic tier does

- **Text** is split into one Tumblr paragraph per line. A paragraph holds at most 4,096 characters, so NEFORUM splits longer lines at a space. A whole post can hold up to 524,288 characters.
- **Title**: shown as a large heading at the top of the post. Tumblr posts have no separate title field.
- **Links** written in the text become clickable. A post's **link** becomes a link preview card at the end of the post, and is also set as the post's **source**.
- **Tags** go into Tumblr's tag field and are not added to the text. Tags cannot contain commas, so NEFORUM turns any comma into a space.
- **Images**: up to 30 per post. JPEG, PNG and WEBP files can be up to 20 MB and must be RGB (CMYK files are refused). GIFs can be up to 10 MB. Alt text is sent with each image.
- **Video**: one uploaded MP4 or MOV per post, up to 500 MB and 10 minutes. You can mix images and a video in one post.
- **Scheduling on Tumblr's side**: if you schedule a post, NEFORUM sends it to Tumblr straight away as a scheduled queue item. Tumblr publishes it at the chosen time, so NEFORUM does not need to be running then.
- **Post state**: the per-post option `state` can be `published` (the default), `queue` (added to your blog's queue), `draft` or `private`. If you set the post's visibility to *private*, NEFORUM creates a private post.

## Set up "Your own API keys"

1. Sign in to Tumblr in your browser and open <https://www.tumblr.com/oauth/apps>. Click **Register application**.
2. Fill in:
   - **Application Name**: anything, e.g. `NEFORUM for Ada`.
   - **Application Website**: any web address, for example `https://github.com/neforum-app/neforum`.
   - **Application Description**: e.g. `Posting from my own NEFORUM app`.
   - **Administrative contact email**: your e-mail address.
   - **Default callback URL**:

     ```
     http://127.0.0.1:52771/callback
     ```

   - **OAuth2 redirect URLs** (space separated). Enter both addresses on one line:

     ```
     http://127.0.0.1:52771/callback neforum://callback/
     ```

     The first one is for NEFORUM on Windows and macOS, the second for Android and iPhone. **Keep the slash at the end of `neforum://callback/`**: Tumblr only accepts app addresses like this one when they end in a slash. Each address must match exactly, character for character.
3. Click **Register**. Tumblr only switches on OAuth 2 for an app once it has at least one OAuth2 redirect URL.
4. On the app list, copy the **OAuth Consumer Key**. Click **Show secret key** and copy the **Secret Key** too.
5. In NEFORUM go to **Accounts > Add > Tumblr > Your own API keys** and paste both keys.
   - **Blog name** (optional): the blog to post to, i.e. the part before `.tumblr.com`. Leave it empty to use your main blog. To post to several blogs, add one NEFORUM account per blog. They can all use the same keys.
6. Click **Connect**. Your browser opens Tumblr's permission page. Click **Allow**. NEFORUM asks for `basic` (read your blog list), `write` (create posts) and `offline_access` (stay signed in).

### If Tumblr refuses the redirect address

Tumblr checks the web address when you save the app. Some addresses are refused with "The url's domain is not valid". Others are known to be refused too, such as home-network IPs like `192.168.x.x`. If `http://127.0.0.1:52771/callback` is refused:

1. Register `http://localhost:52771/callback` instead, as both the default callback and an OAuth2 redirect URL.
2. In NEFORUM, enter the same address in the **Redirect URI (advanced)** field.

On a computer the address must keep port `52771` and the path `/callback`.

### Staying signed in

A Tumblr sign-in lasts only 42 minutes. NEFORUM renews it automatically, and Tumblr hands out a new renewal key each time. If NEFORUM is not used for **42 days**, the renewal key expires and you need to click **Reconnect** once. The same happens if you remove the app's access on Tumblr.

Your Secret Key is stored only in this device's secure storage, next to the sign-in. NEFORUM never sends it anywhere except to Tumblr's sign-in server.

## Hand-off tier

No setup is needed. NEFORUM opens Tumblr's official share tool (`https://www.tumblr.com/widgets/share/tool`), filled in with your text, title and tags. A link post uses Tumblr's link layout. If you are not signed in, Tumblr asks you to sign in first and then opens the filled-in post. Check it and click **Post now**. Your text is also on the clipboard.

Photos and videos cannot be passed to Tumblr's website from another program:

- **Android and iPhone**: NEFORUM opens the share sheet. Pick **Tumblr** (the Android app is `com.tumblr`), and paste the text if the app does not take it.
- **Windows and macOS**: Tumblr has no desktop app. Open tumblr.com, create a post, paste the text and add the files yourself.

## Known limitations

- **No threads.** Tumblr has no reply chains. A long text simply becomes a long post.
- **No content warnings or community labels.** Tumblr's "mature" labels cannot be set through the API. Set them on tumblr.com after posting.
- **No unlisted or followers-only posts.** Such posts are published publicly. Use *private* to hide a post.
- **One video at a time.** Tumblr refuses a new video while the previous one is still processing. NEFORUM shows "still processing your previous video" and retries a few minutes later.
- **Scheduled posts and the queue**: a blog queue holds at most 1,000 posts and publishes at most 50 a day. A Tumblr Premium page mentions a different queue figure (2,000); Tumblr has not clarified which is correct. A scheduled post may get a new ID when it is published, so NEFORUM does not show a link for queued posts.
- **Tags**: Tumblr is commonly said to allow 30 tags per post, and NEFORUM warns above 30. Tumblr's own documentation no longer states this limit, so it is unconfirmed.
- **Daily limits are per Tumblr user**, not per app. Posts you make on tumblr.com or in the Tumblr app count too.
- **Tumblr's rules**: Tumblr's User Guidelines forbid automated or systematic posting aimed at spam. Use NEFORUM for your own, user-initiated posts and keep the volume modest.

## Sources

- Tumblr API documentation (OAuth 2, rate limits, NPF post creation, error codes): <https://github.com/tumblr/docs/blob/master/api.md> (also <https://www.tumblr.com/docs/en/api/v2>)
- Neue Post Format specification (blocks, 4,096 code points per text block, 30 images and 1 uploaded video per post): <https://github.com/tumblr/docs/blob/master/npf-spec.md>
- Writing posts (524,288 characters per post): <https://help.tumblr.com/knowledge-base/writing-posts/>
- Images and GIFs (20 MB, GIF 10 MB, RGB only, 30 images on the web): <https://help.tumblr.com/knowledge-base/image-gif-troubleshooting/>
- Posting video (MP4/MOV, 500 MB, 10 minutes, 20 videos and 60 minutes a day): <https://help.tumblr.com/knowledge-base/posting-video/>
- Queue limits: <https://help.tumblr.com/knowledge-base/queue/>
- Share button / share tool parameters: <https://help.tumblr.com/hc/en-us/share-button-documentation/>
- Register an app: <https://www.tumblr.com/oauth/apps>
- API License Agreement: <https://www.tumblr.com/policy/en/api-license-agreement>
- User Guidelines: <https://www.tumblr.com/policy/en/user-guidelines>
- Redirect URL quirks: <https://github.com/tumblr/docs/issues/122> (custom scheme with trailing slash; `state` is required) and <https://github.com/tumblr/docs/issues/101> (domain validation)
- Token lifetimes (42 minutes / 42 days): <https://github.com/tumblr/docs/issues/134>
- Video media must be an object, not an array: <https://github.com/tumblr/docs/issues/88>

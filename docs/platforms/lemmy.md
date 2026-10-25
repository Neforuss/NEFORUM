# Lemmy setup guide

This guide connects an account on a **Lemmy** instance, such as lemmy.world, lemmy.ml, programming.dev or sh.itjust.works, to NEFORUM. Afterwards NEFORUM posts into the community you choose automatically, with no app to create and no redirect URI to register.

## Steps

1. In NEFORUM, add **Lemmy** and enter your instance, for example `lemmy.world`.
   - You can also paste your handle (`@you@lemmy.world`).
2. Enter your **username** (without `@instance`) or your **email**.
3. Enter your **password**.
4. If you turned on two-factor authentication (Settings > Account > 2FA), also enter the current 6-digit code from your authenticator app.
   - If you leave it out, NEFORUM asks for it.
5. Optionally enter a **default community**, for example `!technology@lemmy.world`.
   - You can also paste the community's web address (`https://lemmy.world/c/technology`).
   - For communities on your own instance, the bare name (`asklemmy`) is enough.
6. Press **Connect**.
7. Optional: tick **Bot account** in your Lemmy settings if you mostly cross-post. Many communities and instances ask automated or cross-posting accounts to do this.

## Steps: Hand-off without a password

1. Log in to your instance in your browser.
2. In NEFORUM, add **Lemmy**, choose **Hand off to the app** and enter your instance and, optionally, a default community.
3. Click **Add Lemmy**.
4. Publish the post in NEFORUM. It opens the instance's **Create post** page with the title, link, text and community filled in, and puts your text on the clipboard.
5. Upload the image on the page with the image button next to the URL field, if your post has one.
6. Press **Create**.

## How it works

Lemmy is a federated, Reddit-like link aggregator: every post has a **title**, goes into a **community**, and can carry a link or an image plus Markdown text.

Status as of October 2026: the Lemmy API is free and open on every instance. There is no developer portal, no app registration and no app review. Any ordinary account can post. NEFORUM uses HTTP API **v3**. Lemmy 0.19.x (current stable: 0.19.20) has it, and Lemmy 1.0 (in open beta since May 2026) still supports it.

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API** (recommended) | An account on a Lemmy instance: username or email and password, plus the 6-digit code if you use two-factor authentication. | Free | By default, **6 posts per 10 minutes** and **6 image uploads per hour** per IP address. Each instance can change these limits and sets its own image size limit. |
| **Hand-off** | An account on the instance, logged in in your browser | Free | NEFORUM opens the instance's **Create post** page with the title, link, text and community filled in. You press **Create** yourself. Images can't be attached automatically. |

Lemmy has no OAuth login for apps, so NEFORUM logs in the same way the website does. When you connect:

- NEFORUM calls `POST /api/v3/user/login` once. Your instance answers with a login token (a JWT), and NEFORUM keeps **only that token**, in your device's secure storage. **Your password is not stored.**
- It reads `GET /api/v3/site` for your profile name, avatar, the Lemmy version and the instance's list of languages.
- It looks up the default community with `GET /api/v3/community?name=...`. If your instance has never seen that community, NEFORUM asks it to fetch it (`resolve_object`).

The token does not expire. It stops working when you log out of that session, change your password, or remove the account in NEFORUM (which logs it out with `POST /api/v3/user/logout`). If that happens, connect again.

## What gets posted

- **Title:** required, 3 to 200 characters, on one line. NEFORUM turns line breaks into spaces. If you leave the title empty, NEFORUM uses the first line of your text.
- **Community:** required. NEFORUM uses the account's default community. To post somewhere else, set `community` (`!name@instance`) or `communityId` in the per-network options for that post.
- **Body:** Markdown, up to 50,000 characters. Long posts are **not** split into threads, because Lemmy has no threads.
- **Link:** your post's link goes into Lemmy's own URL field (http, https or magnet; max 2,000 characters). Lemmy fetches the preview itself.
- **Image:** one image per post. It is uploaded to your instance (`POST /pictrs/image`) and becomes the post's URL. Alt text is sent as `alt_text` (max 1,500 characters). If the post has **both** a link and an image, the link goes in the URL field and the image appears at the top of the body.
- **Video:** only works where the instance admin allows video uploads. Many instances don't.
- **NSFW:** the "sensitive" switch sets Lemmy's NSFW flag.
- **Language:** if your post has a language that your instance knows, NEFORUM sends it. If the community doesn't allow that language, NEFORUM tries once more without a language.
- **Hashtags and content warnings:** Lemmy has neither, so NEFORUM doesn't add `#tags`.

## Limits

- **One community per post.** Cross-posting the same item to several communities on one account takes several targets, and it quickly runs into the 6-posts-per-10-minutes limit. Many communities also treat repeated cross-posts as spam.
- **Image size is set by each instance.** NEFORUM assumes 20 MB, the stock nginx limit, but some instances accept much less (some only a few hundred kB). Some disable uploads for normal users entirely. If your instance refuses the image, post it with a link to an image hosted elsewhere.
- **No server-side scheduling.** Lemmy 1.0 adds scheduled posts, but it's still in beta. NEFORUM schedules posts on your device.
- **Login with SSO or OAuth** (Lemmy 1.0 lets instances offer external identity providers) is not supported. You need a password login.
- **New accounts:** if your instance requires approval or email verification, you can't connect until that's done.
- **Hand-off:** the Create post page can't receive files. Your text goes on the clipboard, and you upload the image on the page with the image button next to the URL field. On Android you can share the image to a third-party Lemmy app such as Jerboa instead. There are no official Lemmy apps for phones. The prefilled page only works while you're logged in to your instance in that browser.

## Mbin, Kbin and PieFed

These look like Lemmy and federate with it, but their APIs are different, so the Lemmy option **does not work** with them. If you try, NEFORUM tells you so.

- **Mbin / Kbin:** a completely different REST API with real OAuth2 logins. Each user would register their own app on their instance (`POST /api/client`; some instances allow only admins to do this). The default limit is just 2 new threads per 6 minutes. **Not supported yet.** You can still post to Mbin magazines from a Lemmy account through federation. Paste the magazine's address as the community, for example `https://kbin.earth/m/fediverse`.
- **PieFed:** says it is "95 % like Lemmy", but its API is at `/api/alpha` and uses different field names (`title` instead of `name`, and `{username, password}` to log in). It is marked alpha and changes often. **Not supported yet.** PieFed communities can also be reached from a Lemmy account through federation.

## Sources

- Lemmy API documentation (lemmy-js-client): https://join-lemmy.org/api/
- API v4 / Lemmy 1.0 notes: https://join-lemmy.org/docs/contributors/09-api-v4.html
- Lemmy 1.0 open beta announcement: https://join-lemmy.org/news/2026-05-19_-_Open_beta_testing_for_Lemmy_1.0.0
- `CreatePost` type (0.19): https://github.com/LemmyNet/lemmy-js-client/blob/release/v0.19/src/types/CreatePost.ts
- Client calls (login, community, upload): https://github.com/LemmyNet/lemmy-js-client/blob/release/v0.19/src/http.ts
- Error codes and HTTP status mapping: https://github.com/LemmyNet/lemmy/blob/release/v0.19/crates/utils/src/error.rs
- Title, body, URL and alt-text limits: https://github.com/LemmyNet/lemmy/blob/main/crates/utils/src/utils/validation.rs
- Rate limiting: https://github.com/LemmyNet/lemmy/blob/release/v0.19/crates/utils/src/rate_limit/mod.rs
- Create post page parameters: https://github.com/LemmyNet/lemmy-ui/blob/release/v0.19/src/shared/components/post/create-post.tsx
- Mbin API for developers: https://docs.joinmbin.org/app_developers/
- PieFed API: `https://<instance>/api/alpha/swagger`

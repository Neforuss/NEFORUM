# Discord setup guide

This guide connects one Discord channel to NEFORUM through an incoming webhook. Afterwards NEFORUM posts there automatically, and by default each post notifies the whole channel with **@everyone**.

## Steps

1. In Discord (desktop or web is easiest), hover over the channel and click the gear icon (**Edit Channel**).
2. Open **Integrations** > **Webhooks** > **New Webhook**.
   - If you don't see this, ask a server admin for the *Manage Webhooks* permission.
3. Click the new webhook.
4. Set the name and avatar your posts should have, and check that the **Channel** is right.
5. Click **Copy Webhook URL**.
   - It looks like `https://discord.com/api/webhooks/123456789012345678/AbCdEf…`.
6. In NEFORUM, add **Discord** and paste the URL.
7. Optional: fill in **Post as** to replace the webhook's name on NEFORUM posts.
   - Up to 80 characters, and it may not contain "discord" or "clyde". Discord refuses posts with such a name, so NEFORUM checks it when you connect.
8. If the webhook belongs to a forum or media channel, turn on **Forum or media channel**.
   - Each post then starts a new forum post, named after the post title (or its first line).
9. Click **Connect**.
10. Optional: to post without notifying everyone, turn off @everyone for Discord under **Settings > Posting**.
    - To change it for one post only, open **Customize** for the Discord target and switch **Mention @everyone**.

## How it works

A webhook is a special posting address for one channel. It needs no bot, no developer account and no sign-in. The webhook's name and picture are shown on each post.

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API** (webhook) | The **Manage Webhooks** permission in the server, and one webhook per channel | Free | Messages up to 2000 characters. Up to 10 files per message, 20 MiB each by default (more on boosted servers), 25 MiB per message in total. Discord limits how fast a webhook may post; when it says "slow down", NEFORUM waits as long as Discord asks. |

Status as of October 2026: webhooks are free and need no review. Running your own bot or logging in as a user is not needed. Automating a normal user account breaks Discord's terms, and NEFORUM never does it.

Discord has no share link that can fill in a message, so NEFORUM has no hand-off option for Discord. On a phone you can always share a picture into the Discord app yourself.

When you connect, NEFORUM checks the webhook once (`GET /webhooks/{id}/{token}`) and stores the server and channel ids, so it can show you a link to each post.

Treat the webhook URL like a password: anyone who has it can post in the channel. If it leaks, delete the webhook in Discord and create a new one. There is no redirect URI and nothing else to register. Webhooks don't expire until someone deletes them.

## What gets posted

- **@everyone** (on by default): the first message of each post starts with `@everyone` on its own line, so everyone in the channel is notified. If your text already contains @everyone or @here, NEFORUM does not add another one. Turn it off under **Settings > Posting**, or for one post with **Mention @everyone** in **Customize**.
- **Other mentions don't ping.** Role and user mentions in cross-posted text show as text but don't ping anyone. The later messages of a long post never ping, and with @everyone turned off, `@everyone` and `@here` in your text show as text only.
- **Text** uses Discord's own Markdown (`**bold**`, `*italic*`, `` `code` ``, `> quote`) and is sent as written. Posts longer than 2000 characters are sent as several messages in a row. If Discord asks NEFORUM to wait up to 10 seconds between them, NEFORUM waits and carries on. If a later message still fails, the earlier ones stay posted and NEFORUM does **not** retry on its own (that would post them twice); the error lists what is already live.
- **Media**: up to 10 images/videos per message, uploaded together with the text. Alt text is sent as the attachment description (max 1024 characters). Media marked **sensitive** is sent as a spoiler.
- **Link previews**: Discord previews every link. Set `disableLinkPreview: true` in the per-network options to turn that off.
- **View post** links have the form `https://discord.com/channels/<server>/<channel>/<message>`.

## Limits

- **One webhook, one channel.** To post in five channels, add five Discord accounts in NEFORUM, one webhook each.
- **The upload limit varies.** Discord's docs say 20 MiB per file by default, but the limit depends on the server's boost level and has changed before. If a file is too big, NEFORUM shows Discord's error. Make the file smaller and try again.
- **No server-side scheduling.** Scheduled posts are sent from your device, so it must be on and online at that time.
- **No replies or threads in a normal channel.** Long posts are just consecutive messages. In forum channels they all go into the same forum post.
- Too many failed requests (for example with a deleted webhook) can get your network blocked by Discord for a while. NEFORUM doesn't retry a webhook that Discord reports as gone. Reconnect with a new one instead.

## Sources

- Webhook resource (Execute Webhook, Get Webhook with Token): https://docs.discord.com/developers/resources/webhook
- Message resource (request size, attachments, flags): https://docs.discord.com/developers/resources/message
- API reference (base URL, versioning, uploading files): https://docs.discord.com/developers/reference
- Rate limits: https://docs.discord.com/developers/topics/rate-limits
- Terms of Service: https://discord.com/terms

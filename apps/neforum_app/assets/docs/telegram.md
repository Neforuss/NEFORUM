# Telegram setup guide

This guide connects a Telegram **channel** or **group** through a **bot that you own**, so NEFORUM posts there for you. The bot posts in the channel's name, the same way your own posts in a channel do; it cannot post to your personal chats or as you.

## Steps

1. In Telegram, open a chat with **@BotFather** (check for the blue verified tick).
2. Send `/newbot`.
3. Choose a display name, then a username that ends in `bot`, for example `my_news_poster_bot`.
4. Copy the **token** BotFather replies with. It looks like `110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw`.
   - Anyone who has this token controls your bot, so don't paste it anywhere else.
   - If it leaks, send `/revoke` to BotFather and connect again with the new token.
5. Add the bot to where it should post:
   - **Channel:** open the channel > **Administrators** > **Add Admin**, search for your bot's username, and leave **Post Messages** switched on. Adding it as a plain subscriber is not enough.
   - **Group:** add the bot as a member. It needs permission to send messages, and to send media if you post images.
6. In NEFORUM, add **Telegram** and paste the token.
7. Enter the chat:
   - a public channel or group: `@channelusername` (or its `https://t.me/channelusername` link)
   - a private channel or group: its numeric id. Channels and supergroups start with `-100`, for example `-1001234567890`; a small basic group has a shorter negative id such as `-123456789`. Bots can't use invite links (`t.me/+…`).
   - To find the id, forward one post from the channel to a bot such as @userinfobot, or open the channel in Telegram Web, where the id is in the address bar.
8. Pick **Formatting**:
   - `markdown` (default) turns `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `> quotes` and `[label](https://…)` links into Telegram formatting.
   - `plain` sends your text exactly as written.
9. Press **Connect**. If anything is missing, NEFORUM tells you what to fix.

There is no redirect URI and nothing to register. Bot tokens never expire.

## Steps: hand-off

1. In NEFORUM, add **Telegram** and choose **Hand-off**.
2. When you publish, pick the chat on Telegram's share page (or in the share sheet when you attach media).
3. Press **Send**.

## Ways to connect

Status as of October 2026: the Telegram Bot API is free. There is no developer portal, no app review and no business account. Any Telegram user can create a bot in about a minute.

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API** (recommended) | A bot token from @BotFather. The bot must be an **administrator with "Post Messages"** in your channel, or a member of your group. | Free | About 1 message per second per chat and 20 messages per minute in a group. If NEFORUM goes faster, Telegram says how many seconds to wait. |
| **Hand-off** | The Telegram app or Telegram Web | Free | NEFORUM opens Telegram's share page (`https://t.me/share/url`) with your text, or the share sheet when you attach media. You pick the chat and press **Send**. |

## How it works

### When you connect

NEFORUM checks the token (`getMe`), looks up the chat (`getChat`) and makes sure the bot is allowed to post there (`getChatMember`).

### Posting

- **Text**: up to 4096 characters per message. Longer posts are split into several messages, and each one is a reply to the one before it.
- **Media**: up to 10 photos and/or MP4 videos per post. One file is sent with `sendPhoto`, `sendVideo` or `sendAnimation` (for GIFs). Two to ten files are sent as an album (`sendMediaGroup`).
  - Photos: up to 10 MB each. Width + height must be at most 10000 pixels, and the long side at most 20 times the short side.
  - Videos and GIFs: up to 50 MB each. A GIF inside an album is sent as a photo, so there the 10 MB photo limit applies.
- **Captions**: a caption on media holds 1024 characters. If your text fits, it becomes the caption. If not, NEFORUM sends the media first and then the full text as a separate message right after it.
- **Sensitive media** is sent with Telegram's spoiler blur.
- **Link**: the post's link is added to the text. Telegram shows a preview for it unless you set `disableLinkPreview: true` in the per-network options. Set `silent: true` to send without a notification sound.
- **View post** links: `https://t.me/<channel>/<id>` for public chats, and `https://t.me/c/<id>/<message>` (members only) for private supergroups and channels.
- **Several messages per post** (media plus a long text, or a long text split into parts): if Telegram asks NEFORUM to slow down between them for up to 10 seconds, NEFORUM waits and carries on. If a later message still fails, the earlier ones stay posted and NEFORUM does **not** retry the post on its own (that would post them twice); the error lists what is already live so you can finish by hand.

## Limits

- **Bots only.** NEFORUM doesn't post as your personal account. That would need Telegram's user API (MTProto), with a phone-code login and stricter terms.
- **No server-side scheduling.** The Bot API can't schedule messages. Scheduled posts are sent from your device, so it must be on and online at that time.
- **No alt text.** Telegram has no image descriptions.
- **GIFs in albums become still pictures.** Post a GIF on its own to keep the animation.
- **Only MP4 video.** Telegram plays MP4 (H.264/AAC). Convert other formats first.
- **Thread replies in channels** show as replies only to people who open the discussion or the reply chain. In the channel itself the parts appear one after another.
- The bot token is part of every Bot API address. NEFORUM keeps it out of error messages. Don't share debug logs publicly.

## Troubleshooting

- **Posting fails with a message asking you to reconnect after a group was upgraded**: groups upgraded to supergroups get a new id. Reconnect the account.

## Sources

- Bot API reference (Bot API 10.3): https://core.telegram.org/bots/api
- Sending files and size limits: https://core.telegram.org/bots/api#sending-files
- `sendMessage`, `sendPhoto`, `sendVideo`, `sendMediaGroup`: https://core.telegram.org/bots/api#available-methods
- Formatting options (HTML): https://core.telegram.org/bots/api#formatting-options
- Bot FAQ (rate limits): https://core.telegram.org/bots/faq
- BotFather and bot features: https://core.telegram.org/bots/features
- Share link: https://core.telegram.org/widgets/share
- Deep links (`tg://`): https://core.telegram.org/api/links

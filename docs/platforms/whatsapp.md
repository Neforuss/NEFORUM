# WhatsApp

NEFORUM reaches WhatsApp by **hand-off only**. Nothing to set up, no developer app, no sign-in.

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Hand-off** (only tier) | Any WhatsApp account. The WhatsApp app (phone), or WhatsApp Web / Desktop (computer) | Free | WhatsApp opens with your text or media. You pick a chat, **My status** or a **Channel** and tap **Send**. |

Status as of October 2026.

## Why there is no automatic posting

- WhatsApp has **no public API for Status or Channels**.
- The **WhatsApp Business Platform** (Cloud API) is a paid service for businesses to message their customers. It needs a Meta business portfolio, a WhatsApp Business Account and a dedicated business phone number. Since 1 July 2025 it bills per message. It **cannot** post to Status or Channels either, so it does not help a cross-poster.
- Unofficial libraries that act like WhatsApp Web (for example Baileys) break WhatsApp's terms of service and often get numbers banned. NEFORUM does not use them.

## Setting it up

1. In NEFORUM, add an account and choose **WhatsApp**.
2. Optionally type a label (for example "Family groups" or "My channel"). Tap **Connect**. That's it.

## What happens when you publish

- **Text only:** NEFORUM opens `https://wa.me/?text=...` with your text already filled in. On a phone this opens the WhatsApp app. On a computer it goes on to WhatsApp Web, or to WhatsApp Desktop if it is installed. Choose a chat or one of your Channels and tap **Send**.
  For a **text Status**, open **Updates**, tap the pencil, paste (your text is on the clipboard) and send.
- **With photos or videos (phone):** NEFORUM opens the share sheet with your files. Pick **WhatsApp**, then choose **My status**, a Channel or a chat. Your text goes along as the caption and is also on the clipboard in case WhatsApp drops it.
- **With photos or videos (computer):** open WhatsApp Web/Desktop, attach the files and paste the text.

## Limits

- Text: WhatsApp publishes no length limit for messages. Status text is typed in WhatsApp itself.
- Media: up to 100 photos or videos at once (WhatsApp Help Center, web/desktop). WhatsApp compresses photos and videos. On Status, every photo or video becomes its own update. Status videos are cut at about 60 seconds; older app versions cut them at 30 s. This limit is reported, not documented.
- No alt text, no threads, no scheduling.

## Known limitations

- NEFORUM **cannot preselect** Status or a Channel. You always choose the target in WhatsApp.
- A thread that NEFORUM would split elsewhere is sent here as one message, with the parts separated by blank lines.
- The `wa.me` link carries text only. Media always goes through the share sheet.
- WhatsApp Business users: the share sheet also lists the **WhatsApp Business** app (`com.whatsapp.w4b`); it works the same way.

## Sources

- Click to chat, checked live 2026-10-07/10: `https://wa.me/?text=hello%20world` redirects to `https://api.whatsapp.com/send/?text=hello+world&type=custom_url&app_absent=0`
- How to use click to chat: https://faq.whatsapp.com/5913398998672934
- How to send media (web/desktop): https://faq.whatsapp.com/en/web/28080001
- How to create and share status updates: https://faq.whatsapp.com/en/android/26000031
- WhatsApp Business Platform overview: https://developers.facebook.com/docs/whatsapp/overview
- WhatsApp Business Platform pricing: https://developers.facebook.com/docs/whatsapp/pricing

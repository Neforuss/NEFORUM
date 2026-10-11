# Substack Notes

NEFORUM reaches Substack **Notes** (Substack's short-post feed) by **hand-off only**. Nothing to set up, no API key, no sign-in.

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Hand-off** (only tier) | Any Substack account. You do not need your own publication | Free | NEFORUM copies your text and opens Substack. You paste it into the Notes composer and click **Post**. |

Status as of October 2026.

## Why there is no automatic posting

- Substack has **no publishing API**. Its official Developer API only reads public profile data.
- Unofficial tools such as python-substack log in with your browser cookie and call undocumented parts of the site. Substack's Terms of Use forbid automated access, and those tools can break at any time. NEFORUM does not use them.
- The Notes composer does not accept any URL parameters, so not even the text can be prefilled.

## Setting it up

1. In NEFORUM, add an account and choose **Substack Notes**.
2. Optionally type a label, for example your Substack handle. Tap **Connect**. That's it.

## What happens when you publish

1. NEFORUM copies your text to the clipboard and opens <https://substack.com/home>. Sign in there once if you are not signed in yet.
2. Click **What's on your mind?** at the top. In the app, open the **Notes** tab and tap **+**.
3. Paste your text and add your images with the photo icon.
4. Click **Post**.

## Limits

- Text: Substack publishes no limit. Its FAQ says "We dare you to try to figure out the character limit."
- Up to **6 images or GIFs** per note. GIFs can only be added on the web. Images and video cannot be mixed. Video in notes is newer and only mentioned for the app.
- Formatting (bold, italic, links) and @mentions are added in Substack's composer. A pasted URL turns into a link preview.
- Hashtags have no special meaning on Substack, so NEFORUM does not add them.
- Substack can schedule notes itself (three dots at the top of the composer > **Schedule**). NEFORUM does not control that.

## Known limitations

- You always paste the text yourself.
- The Android app is `com.substack.app` (its Google Play listing), but Substack does not document a share target. NEFORUM shares files to it, but whether they land in a new note depends on the app.

## Sources

- Notes FAQ (character limit, 6 images/GIFs, web-only features): https://on.substack.com/p/notes-faq
- Getting started on Substack Notes: https://support.substack.com/hc/en-us/articles/14564821756308-Getting-started-on-Substack-Notes
- Substack API terms (read-only Developer API): https://substack.com/api-tos
- python-substack (unofficial, not used): https://github.com/ma2za/python-substack

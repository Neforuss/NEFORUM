# Sound files: voice notes and music

Drop a sound file into the composer and NEFORUM sends it everywhere it can go: as a playable file where a network takes sound, as a video where a network only takes video, and as a link where a network takes neither.

## Steps

1. Drag the file onto the composer, paste it, or press **Add** (on a phone, pick **Sound file**). NEFORUM takes **MP3, M4A (AAC or Apple Lossless), WAV, FLAC, AIFF, Ogg Vorbis and Opus**.
2. The file appears in the tray with its name, length and size. A lossless file (WAV, FLAC, AIFF, Apple Lossless) has a yellow **Lossless** badge.
3. Under the tray, choose the **Audio quality**:
   - **Standard (MP3)**, the default: one compressed file for every network. An MP3 goes as it is; anything else is converted once, at 256 kbit/s, when you save or publish.
   - **Lossless (original file)**: networks that take your file's type get the original. Only offered for lossless files: an MP3 or AAC file turned into WAV would only be bigger, never better.
4. Each network's preview says what it gets ("Telegram gets your original FLAC file, unchanged", "X takes sound only as a video…").
5. Publish or schedule as usual.

## How it works

### MP3 or M4A?

The Standard copy is an MP3 where the device has an MP3 encoder (Windows). Phones and Macs have no MP3 encoder in the system, so they make an **M4A (AAC, 256 kbit/s)** instead; every network that takes sound plays it. A device that cannot convert sound at all (Linux, the web preview) sends the original file wherever it is taken, and says so.

### Video-only networks

X, Bluesky, Instagram, Threads, Facebook, TikTok, YouTube, LinkedIn, Pinterest, Rumble and BitChute take no sound files. NEFORUM makes a video for each of them when you save: one still picture for the whole track, with the sound at 256 kbit/s AAC.

- **Picture:** the post's first photo, else the track's cover art, shown whole: fitted to the frame the way *Settings > Posting > When a photo does not fit a network* says (on a blur of its own colours, or filled with its colours). A square cover in Instagram's 9:16 frame keeps its sides, also in the profile grid, which shows the middle of a Reel. Only **Crop it to fit** cuts the picture to fill the frame. Without a photo or cover, a card with the track's title (the post title, else the file name), the post's first words, and the file type and length, on the NEFORUM purple.
- **Frame:** 1080 x 1920 on TikTok and Instagram (Reels), 1920 x 1080 on YouTube (an upright or square video would become a Short), 1080 x 1080 elsewhere.
- The network's video limits apply: X, for example, takes videos up to 20 minutes.
- On a device that cannot make videos (Linux, the web preview) these networks show "takes sound only as a video; this device can't make one".

### Link-only networks

Nostr, Lemmy, Reddit, DEV, Hashnode, Micropub, WriteFreely and Tumblr get a **link** to the file at the end of the post. The file goes on your media host first ([Settings > Media hosting](media-hosts.md)); Nostr uses its own media server (NIP-96) when one is set. The link stays in the post, so a host that only makes temporary links (Litterbox) is refused: use a bucket you own.

### Per network

| Network | How the track goes | Types taken | Size limit | Original kept byte for byte |
|---|---|---|---|---|
| Telegram | MP3 and AAC play in the chat (sendAudio); lossless and Ogg go as a document (sendDocument) | all | 50 MB (bot upload limit) | yes, as a document |
| Discord | attachment that plays in the channel, with photos | all | 20 MiB per file, 25 MiB per message | yes |
| Matrix | `m.audio` message after the text | all | set by the homeserver (read when you connect) | yes |
| Mastodon | sound attachment, on its own; the server makes its own MP3 | MP3, M4A, WAV, FLAC, Ogg (no AIFF); other Mastodon-API servers: the types they list, else a video | the server's video limit (99 MB on vanilla Mastodon) | no |
| Misskey | Drive file, with photos and videos | the server's allowed types | the server's file limit | yes |
| WordPress | media library plus an audio block | MP3, M4A, WAV, Ogg, FLAC (no AIFF) | your host's upload limit | yes |
| Ghost | media upload plus a player in an HTML card | MP3, WAV, Ogg, M4A (no FLAC or AIFF) | your Ghost setup | yes |
| Odysee | published from the file, never re-encoded | MP3, M4A, Ogg, WAV, FLAC | none (read from disk) | yes |
| X, Bluesky, Instagram, Threads, Facebook, TikTok, YouTube, LinkedIn, Pinterest, Rumble, BitChute | still-picture video made by NEFORUM | any | the network's video limits | no (it is a video) |
| Nostr | link with an `imeta` tag, on the NIP-96 server or media host | any the server takes | the server's | depends on the server |
| Lemmy, Reddit, DEV, Hashnode, Micropub, WriteFreely, Tumblr | link on your media host | any | the host's | yes, on the host |
| Snapchat, WhatsApp, Substack Notes, Google Business Profile, art sites | left out (the post goes without it) | none | | |

With **Lossless**, a network that does not take the original's type gets the Standard copy instead (Mastodon and AIFF, Ghost and FLAC). Telegram and Mastodon take one sound file per post, alone: the post's photos are left out there.

# Nostr

Nostr is an open protocol, not a company. Your identity is a **key pair**: a public key (`npub1...`) that people follow, and a private key (`nsec1...`) that signs your posts. Notes are sent to **relays**, which are servers that store and pass them on. Any Nostr app (Damus, Amethyst, Primal, Snort, Coracle, ...) shows notes from the same relays.

Status as of October 2026: free and open. You don't sign up for anything, there's no developer portal, no API key and no app review. Personal accounts are all there is.

## Ways to connect

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API** (the only tier) | Your Nostr private key (`nsec1...`) and a list of relays | Free | No protocol quota. Each relay sets its own rules (see *Known limitations*). Free media uploads to nostr.build are capped at 20 MB per file. |

There's no hand-off tier. The open tier needs no sign-up or review, so hand-off would add nothing.

## Step by step

There's no app to create and no redirect URI to register. NEFORUM never opens a browser for Nostr.

1. **Get your private key.**
   - If you already use Nostr, open your app's settings and look for *Keys*, *Security* or *Backup*. Copy the key that starts with **`nsec1`**. Your public key (`npub1...`) won't work, because it can't sign.
   - If you're new, any Nostr app can create a key pair for you. Write the `nsec` down somewhere safe, because nobody can recover it for you.
2. In NEFORUM, add **Nostr** and paste the key into **Private key (nsec)**. You can also paste the 64-character hex form of the key.
3. **Relays**: leave the defaults unless you know which relays you write to. The defaults are:
   ```
   wss://relay.damus.io
   wss://nos.lol
   wss://relay.primal.net
   wss://relay.nostr.band
   ```
   Put one `wss://` address per line. Your other Nostr apps show your write relays under *Relays* in their settings. Copy those for the best reach.
4. **Media server (NIP-96)**: leave `https://nostr.build` to upload images and videos there for free. You can enter another NIP-96 server, for example `https://nostrcheck.me`. Leave the field empty if you'd rather upload only to the media host you set up in NEFORUM's settings (S3, WebDAV, ...).
5. Press **Connect**. NEFORUM works out your public key on your device. Nothing is sent anywhere during this step.

### How NEFORUM stores your key

- The private key goes into your device's secure storage (Keychain, Android Keystore or Windows Credential Manager). It is never logged and never sent to a relay or media server. Only the **signatures** made with it leave your device.
- Your public key, relay list and media server are saved as ordinary account settings.
- Anyone who has your `nsec` can post as you, forever, and you can't change a Nostr key. Treat it like a password you can never reset.

## What happens when you publish

1. **Media first.** If the post has images or videos, NEFORUM uploads each one:
   - to your NEFORUM **media host** if you set one up in Settings, otherwise
   - to your **NIP-96 server** (nostr.build by default). NEFORUM reads the server's `/.well-known/nostr/nip96.json` and uploads the file there. It proves the upload is yours with a short-lived signed event (NIP-98, kind 27235).

   The file's address goes at the end of your note. An `imeta` tag (NIP-92) carries the file type, size in pixels, hash and alt text, so apps can show the image properly.
2. **The note** is a standard kind-1 event that NEFORUM signs on your device (NIP-01, BIP-340 Schnorr). Hashtags in your text also become `t` tags, so hashtag searches find the note. Links become `r` tags. A content warning becomes a `content-warning` tag (NIP-36).
3. **Relays.** NEFORUM sends the note to every relay in your list at once and waits up to 8 seconds for each one to reply. The note counts as **published when at least one relay accepts it**. Relays that refused or didn't answer show up in the log. If a relay asks NEFORUM to sign in (NIP-42), NEFORUM signs in with your key and sends the note again.
4. **Threads.** A post split into parts goes out as a chain of replies (NIP-10). Each part replies to the first one, and media goes on the first part.
5. The link NEFORUM shows afterwards is `https://njump.me/note1...`. It opens in any browser, even without a Nostr app.

## Known limitations

- **Relays decide.** A relay may be paid, invite-only or rate-limited, or it may require proof-of-work. NEFORUM tells you which of these happened:
  - *rate-limited*: try again later.
  - *restricted*, *blocked* or *auth-required*: that relay doesn't take notes from your key. Use other relays.
  - *pow*: the relay requires proof-of-work, which NEFORUM doesn't do yet.
- **Size.** The protocol has no character limit, but relays limit the size of a whole event, often to 64 KB (strfry) or 128 KB (nostr-rs-relay). NEFORUM warns you before you post a very long note.
- **nostr.build free plan**: 20 MB per file, and you have to be signed in with your key (NIP-98). That's why NEFORUM blocks larger files when nostr.build is the media server. With another server, that check becomes a warning only. Paid nostr.build plans and nostrcheck.me (100 MB free) allow bigger files.
- **No remote signers yet.** NEFORUM can't yet use a remote signer: no NIP-46 bunker such as nsec.app, and no Amber on Android (NIP-55). For now you have to paste your `nsec`.
- **Your relay list is not read from Nostr.** NEFORUM uses the relays you entered and doesn't fetch your published relay list (NIP-65, kind 10002).
- **No Blossom uploads** (the newer BUD-02 upload method) yet. Use a NIP-96 server or your NEFORUM media host.
- **No server-side scheduling.** Relays reject notes dated far in the future. Scheduled posts stay in NEFORUM and are signed and sent at the scheduled time, so NEFORUM must be running then.
- **Everything is public.** Nostr has no "followers only" or "unlisted" setting. A note can't truly be deleted either: deletion requests (NIP-09) are only hints that relays may ignore.
- **Default relays.** The default relays are well-known public relays, but they come from community knowledge, not from an official list. Any of them can change its rules at any time.

## Sources

- NIP-01 Basic protocol (event format, id serialisation, `OK` messages): https://github.com/nostr-protocol/nips/blob/master/01.md
- NIP-10 Threads and replies: https://github.com/nostr-protocol/nips/blob/master/10.md
- NIP-19 bech32 entities (npub, nsec, note): https://github.com/nostr-protocol/nips/blob/master/19.md
- NIP-36 Content warnings: https://github.com/nostr-protocol/nips/blob/master/36.md
- NIP-42 Relay authentication: https://github.com/nostr-protocol/nips/blob/master/42.md
- NIP-92 Media attachments (`imeta`): https://github.com/nostr-protocol/nips/blob/master/92.md
- NIP-96 HTTP file storage: https://github.com/nostr-protocol/nips/blob/master/96.md
- NIP-98 HTTP auth: https://github.com/nostr-protocol/nips/blob/master/98.md
- NIP-11 Relay information: https://github.com/nostr-protocol/nips/blob/master/11.md
- nostr.build NIP-96 info: https://nostr.build/.well-known/nostr/nip96.json
- nostr.build plans: https://account.nostr.build/plans
- strfry default limits: https://github.com/hoytech/strfry/blob/master/strfry.conf
- nostr-rs-relay default limits: https://github.com/scsibug/nostr-rs-relay/blob/master/config.toml

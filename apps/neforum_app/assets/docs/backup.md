# Move to another device

This guide puts your accounts, their keys and your settings into **one encrypted file** that you carry to another device yourself, for example from your PC to your phone and back. There is no cloud and no NEFORUM server: the file never passes through Neforus.

## Steps: On the device that has your accounts

1. Go to **Settings > Data & privacy > Move to another device > Export…**
2. Choose **Copy** or **Move** (see "Copy or Move" under How it works).
3. Choose what to include.
4. Note the passphrase: write it down or keep it in your password manager.
5. Tick **I have written this passphrase down**.
6. Choose **Encrypt and save**.
   - On a computer you choose where to save `neforum-<device>-<date>.neforumbackup`.
   - On a phone the share sheet opens: send it with LocalSend, Nearby Share, AirDrop, a USB cable or a memory card.

## Steps: On the other device

1. Copy the file there (Downloads, Files, a USB stick).
2. Go to **Settings > Data & privacy > Move to another device > Import…** and pick the file.
3. Type the passphrase. Unlocking takes a moment on purpose: it makes guessing passphrases slow.
4. Check the preview and untick anything you don't want.
5. For an account that is already on this device, choose **Replace** (the file's) or **Keep this device's**.
6. Choose **Import**.
   - Posts that were scheduled on the other device arrive as **drafts** with their time, so only one device publishes them: schedule them again where they should go out. Copies a platform already holds (for example a scheduled Facebook post) are not sent again.
7. If you chose **Move**: on the first device, open **Settings > Data & privacy** and choose **Remove them here** (or **Use them here again** if you changed your mind).
8. Optional: check that each account arrived set up the same way. On both devices, go to **Accounts** and open **Connection** on the account's card: it shows its server, your own app or client ID, its Page, board or channel, when the sign-in runs out and which keys the device holds. **Copy all setups** at the top of the page puts every account's setup in your clipboard to compare. Keys, passwords and tokens are never shown or copied.

It works the same in both directions: PC to phone, phone to PC, Mac to iPhone.

## How it works

Want your devices to stay the same all the time instead of moving a file once? Use [Sync between devices](sync.md): one encrypted file in your OneDrive, Google Drive, Dropbox, iCloud Drive, Nextcloud, S3 bucket or other storage.

### Copy or Move

- **Copy:** both devices keep the accounts.
- **Move:** after saving the file, the accounts are switched off on this device, so nothing posts twice. When the other device has imported them, open **Settings > Data & privacy** here and choose **Remove them here** (or **Use them here again** if you changed your mind).

**X, Tumblr, TikTok, DeviantArt and Pixelfed can stay connected on only one device.** Every time they renew a sign-in they invalidate the previous one, so after a Copy, whichever device renews first ends the other's connection. Reconnect them on the device that should keep them, or use Move. This does not apply to X and Tumblr accounts connected with OAuth 1.0a keys, which are never renewed (X stops accepting those on 31 January 2027): see "Stay connected on several devices" in the [X](platforms/x.md) and [Tumblr](platforms/tumblr.md) guides.

### What is in the file

| Included | Default |
|---|---|
| Accounts and their keys (tokens, API keys, app passwords) | On |
| Media hosts and their keys | On |
| Settings (theme, text cards, photo fitting, posting rules, default targets) | On |
| Drafts and scheduled posts | On |
| Published post history | Off |
| Photos and videos | Never (drafts arrive without them) |
| Font files | Never. A style that names a font arrives; the other device draws the default font until it has that font, and offers one-tap download if the font came from the font list |

Settings that belong to one device stay there: starting at sign-in, keeping NEFORUM in the tray, the browser extension and its paired browsers.

### The passphrase

NEFORUM suggests a random passphrase such as `K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG` (24 characters, about 120 bits). You can use your own instead: at least 10 characters, 14 or more recommended.

A code like the suggested one can be typed in small letters and without the dashes: NEFORUM writes it in capitals and adds the dashes as you type, and keeps it that way. That happens to your own passphrase too when it is made only of those letters and digits (24 at most). Any other passphrase is kept exactly as you type it. A backup locked before NEFORUM 1.4.3 with such a passphrase in small letters still opens: type it the way you set it.

**Write it down or keep it in your password manager.** Without it the file cannot be opened, by you or by anyone else. There is no recovery. The passphrase is never put in the file name or in what you share.

## How the file is protected

- Your passphrase is stretched with **Argon2id** (19 MiB of memory, 2 passes), which makes each guess cost the same work for anyone trying to break it.
- The contents are encrypted with **AES-256-GCM**. The file's header (format, key-stretching settings, salt and nonce) is authenticated too, so a changed file, a wrong passphrase, or a header lowered to make guessing cheaper is refused: "Wrong passphrase or damaged file".
- Nothing is written to disk unencrypted: the file is built and opened in memory.
- File layout: `NEFORUMB` magic, version, key-stretching settings, salt, nonce, then the encrypted, compressed contents. The code is in `packages/neforum_core/lib/src/backup/`.

A NEFORUM backup is your own copy. Deleting your data in NEFORUM does not delete backup files you made; delete those yourself when you no longer need them.

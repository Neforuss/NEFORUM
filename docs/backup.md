# Move to another device

NEFORUM can put your accounts, their keys and your settings into **one encrypted file** that you carry to another device yourself, for example from your PC to your phone and back. There is no cloud and no NEFORUM server: the file never passes through Neforus.

You'll find it in **Settings > Data & privacy > Move to another device**.

Want your devices to stay the same all the time instead of moving a file once? Use [Sync between devices](sync.md): one encrypted file in your OneDrive, Google Drive, Dropbox, iCloud Drive, Nextcloud, S3 bucket or other storage.

## What is in the file

| Included | Default |
|---|---|
| Accounts and their keys (tokens, API keys, app passwords) | On |
| Media hosts and their keys | On |
| Settings (theme, text cards, photo fitting, posting rules, default targets) | On |
| Drafts and scheduled posts | On |
| Published post history | Off |
| Photos and videos | Never (drafts arrive without them) |

Settings that belong to one device stay there: starting at sign-in, keeping NEFORUM in the tray, the browser extension and its paired browsers.

## Copy or Move

- **Copy:** both devices keep the accounts.
- **Move:** after saving the file, the accounts are switched off on this device, so nothing posts twice. When the other device has imported them, open **Settings > Data & privacy** here and choose **Remove them here** (or **Use them here again** if you changed your mind).

**X and Tumblr can stay connected on only one device.** Every time they renew a sign-in they invalidate the previous one, so after a Copy, whichever device renews first ends the other's connection. Reconnect them on the device that should keep them, or use Move. This does not apply to X and Tumblr accounts connected with OAuth 1.0a keys, which are never renewed: see "Stay connected on several devices" in the [X](platforms/x.md) and [Tumblr](platforms/tumblr.md) guides.

## The passphrase

NEFORUM suggests a random passphrase such as `K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG` (24 characters, about 120 bits). You can use your own instead: at least 10 characters, 14 or more recommended.

**Write it down or keep it in your password manager.** Without it the file cannot be opened, by you or by anyone else. There is no recovery. The passphrase is never put in the file name or in what you share.

## Step by step

### On the device that has your accounts

1. **Settings > Data & privacy > Move to another device > Export…**
2. Choose **Copy** or **Move** and what to include.
3. Note the passphrase and tick **I have written this passphrase down**.
4. **Encrypt and save.** On a computer you choose where to save `neforum-<device>-<date>.neforumbackup`. On a phone the share sheet opens: send it with LocalSend, Nearby Share, AirDrop, a USB cable or a memory card.

### On the other device

1. Copy the file there (Downloads, Files, a USB stick).
2. **Settings > Data & privacy > Move to another device > Import…** and pick the file.
3. Type the passphrase. Unlocking takes a moment on purpose: it makes guessing passphrases slow.
4. Check the preview. Untick anything you don't want. For an account that is already on this device, choose **Replace** (the file's) or **Keep this device's**.
5. **Import.** Posts that were scheduled on the other device arrive as **drafts** with their time, so only one device publishes them: schedule them again where they should go out. Copies a platform already holds (for example a scheduled Facebook post) are not sent again.

It works the same in both directions: PC to phone, phone to PC, Mac to iPhone.

## How the file is protected

- Your passphrase is stretched with **Argon2id** (19 MiB of memory, 2 passes), which makes each guess cost the same work for anyone trying to break it.
- The contents are encrypted with **AES-256-GCM**. The file's header (format, key-stretching settings, salt and nonce) is authenticated too, so a changed file, a wrong passphrase, or a header lowered to make guessing cheaper is refused: "Wrong passphrase or damaged file".
- Nothing is written to disk unencrypted: the file is built and opened in memory.
- File layout: `NEFORUMB` magic, version, key-stretching settings, salt, nonce, then the encrypted, compressed contents. The code is in `packages/neforum_core/lib/src/backup/`.

A NEFORUM backup is your own copy. Deleting your data in NEFORUM does not delete backup files you made; delete those yourself when you no longer need them.

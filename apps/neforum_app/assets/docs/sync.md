# Sync between devices

NEFORUM can keep your accounts, their keys, your posts and your settings the same on all your computers and phones. Like KeePassXC, it keeps **one encrypted file** in storage you already use, and every device reads and writes that file. There is no NEFORUM server and no NEFORUM account. Your storage provider only ever sees an encrypted file.

You'll find it in **Settings > Sync**.

## Where the file can live

**A cloud app on your computer** (computers only). NEFORUM writes the file into a folder; your cloud app does the syncing.

- OneDrive, Google Drive (Drive for desktop), Dropbox, iCloud Drive, Box Drive, MEGA, pCloud Drive, Proton Drive, Sync.com
- Syncthing (no cloud at all: your devices sync with each other directly)
- The Nextcloud or ownCloud desktop client
- Any other folder that is kept in sync, or a network share

Keep the folder **available offline** ("Always keep on this device" in OneDrive, "Available offline" in Google Drive and Dropbox). Otherwise the cloud app may not download the newest file before NEFORUM reads it.

**WebDAV** (computers and phones). NEFORUM talks to the server itself.

- Nextcloud and ownCloud, Koofr, pCloud, Infomaniak kDrive, Fastmail Files
- A Hetzner Storage Box
- A Synology or QNAP NAS
- Any other WebDAV server

Use an **app password** wherever the service offers one.

**S3-compatible object storage** (computers and phones). NEFORUM talks to the bucket itself.

- Amazon S3, Cloudflare R2, Backblaze B2, Wasabi, IDrive e2, Scaleway, DigitalOcean Spaces, Hetzner Object Storage, Storj
- MinIO
- Any other S3-compatible store

Use a private bucket and a key that can only read and write that bucket.

**Phones cannot use a cloud app's folder.** On a phone, pick WebDAV or S3. Your computers can use the same server or bucket directly, or they can stay on their folder if the cloud service also offers WebDAV (Nextcloud, Koofr, pCloud).

Every device must use the same storage and the same file.

## Turning it on

### On your first device

1. Go to **Settings > Sync > Set up…** and pick your storage.
2. Choose the folder, or fill in the WebDAV address or the S3 bucket and key.
3. Choose a **sync passphrase**. You can use **Generate** for a random one. Write it down or keep it in your password manager. Without it, the file cannot be opened by you or by anyone else, and there is no recovery.
4. Choose **Turn on sync**. NEFORUM creates `NEFORUM.neforumsync` and puts everything in it.

### On each other device

Do the same steps with the same storage and the **same passphrase**. NEFORUM opens the existing file and adds what the device has. Where both have the same thing, the file's version is kept.

Hand-off accounts that you set up on both devices before syncing become one account.

## What syncs

| Synced | |
|---|---|
| Accounts and their keys | Yes |
| Drafts, scheduled posts and history | Yes |
| Settings (theme, text cards, photo fitting, posting rules, default targets) | Yes |
| Media hosts and their keys | Yes |
| Photos and videos | No: they stay on the device they were added on |
| Device settings (tray, start at sign-in, browser extension, Sync itself) | No |

NEFORUM syncs when it starts, every five minutes, and a few seconds after you change something. You can also choose **Sync now** at any time.

## When two devices change the same thing

Each account, post and setting merges on its own, so changes on different things never clash. When the same thing was changed on two devices before they synced:

- A post that has already gone out beats a later edit, so nothing is posted twice.
- Otherwise, the newer edit wins.
- For a sign-in, the most recently renewed keys win, because those are the ones the network still accepts.
- An edit beats a deletion, so nothing you were working on disappears.

Cloud apps sometimes keep two copies when two devices save at the same moment, for example "NEFORUM (conflicted copy).neforumsync". NEFORUM merges such copies into the main file and then removes them.

## X and Tumblr

X and Tumblr give out a new sign-in key every time one is renewed, and the old key stops working. Normally that means an account copied to two devices stays connected on only one of them. With Sync, NEFORUM handles it three ways:

1. **One renewer at a time.** The device that renews first marks the account as being renewed in the sync file. The other devices wait for it.
2. **The newest keys travel.** The renewed keys go into the file right away, and the other devices use them instead of renewing themselves.
3. **Retry after a refusal.** If X or Tumblr refuses a device's keys because another device renewed a moment earlier, NEFORUM reads the file again and retries with the newer keys. With a cloud app's folder, the new file can take a minute to arrive, so NEFORUM tries again a little later instead of asking you to reconnect.

You can avoid renewals altogether by connecting X and Tumblr with **OAuth 1.0a keys**, which never expire. See "Stay connected on several devices" in the [X](platforms/x.md) and [Tumblr](platforms/tumblr.md) guides.

## Scheduled posts

**A scheduled post is published by the device it was scheduled on**, because that device has its photos and videos. Your other devices show the post but leave it alone.

If that device stays silent (switched off, or NEFORUM closed) and the post is more than 30 minutes overdue, another device publishes it instead. It only does so if it has all of the post's photos and videos, so a text-only post can always be picked up.

Platforms that hold scheduled posts themselves (see **Settings > Scheduling**) publish on time either way.

## Safety

- The file uses the same encryption as **Move to another device**. The passphrase is stretched with Argon2id (19 MiB, 2 passes) and everything is encrypted with AES-256-GCM. Any change to the file makes it unreadable instead of wrong.
- The passphrase and your storage password stay in this device's system keychain.
- NEFORUM never makes the file public. It needs no sharing link, and a private bucket is enough.
- To change the passphrase, turn Sync off on every device, delete `NEFORUM.neforumsync`, then set it up again with the new passphrase.

## Turning it off

Go to **Settings > Sync > Turn off**. This device keeps everything it has and stops using the file. The file and your other devices are not changed.

## If something goes wrong

**"The sync passphrase does not open the sync file"**
Use the passphrase you chose on your first device.

**"The folder is not there"**
Start the cloud app, or reconnect the drive.

**Changes take long to arrive with a cloud app**
The cloud app decides when to upload. Check that it is running and that the folder is available offline.

**On a Mac, sync stopped after moving the folder**
Choose **Change…** and pick the folder again.

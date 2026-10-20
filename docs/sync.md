# Sync between devices

NEFORUM can keep your accounts, their keys, your posts and your settings the same on all your computers and phones. Like KeePassXC, it keeps **one encrypted file** in storage you already use, and every device reads and writes that file. There is no NEFORUM server and no NEFORUM account. Your storage provider only ever sees an encrypted file.

You'll find it in **Settings > Sync**.

## Where the file can live

**Google Drive (direct)** (computers, iPhone, iPad and Android). NEFORUM talks to Google Drive itself. It keeps the file in a **NEFORUM Sync** folder in your My Drive. This is the way to use Google Drive on a phone or tablet: Google Drive's iPhone and iPad app does not let other apps pick its folders, and it often does not hand files over to them. **Every device must use Google Drive (direct)**, your computers too, because NEFORUM cannot see a file that Google Drive for desktop put in another folder.

It uses your own Google Cloud project, once, the same way NEFORUM's YouTube connection does (you can reuse that project):

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project, or open the one you use for YouTube.
2. **APIs & Services > Library**: enable the **Google Drive API**.
3. **OAuth consent screen** (Google Auth Platform): choose **External**, fill in the app name and your email, then add the scope `.../auth/drive.file` under **Data access**. This scope only lets NEFORUM see files it made itself.
4. **Audience > Test users**: click **Add users** and add **your own Google address**. Add every Google account you will sign in with, on any device: the one whose Drive should hold the sync file. Without this, Google refuses the sign-in. This Google Cloud app is only for you. You don't share it, and nobody else uses your Client ID.
5. Optional: also under **Audience**, click **Publish app**. While an app is in "Testing", Google ends its sign-ins after 7 days, and NEFORUM asks you to sign in again. With only the `drive.file` scope, publishing needs no review from Google.
6. **Clients > Create client**, type **Desktop app**. Copy the **Client ID** and **Client secret**.
7. In NEFORUM, go to **Settings > Sync > Set up > Google Drive (direct)**, paste them, and sign in with the Google account you added as a test user. Do this on every device with the same Client ID, secret and passphrase.

**A cloud app on your computer.** NEFORUM writes the file into a folder; your cloud app does the syncing.

- OneDrive, Dropbox, iCloud Drive, Box Drive, MEGA, pCloud Drive, Proton Drive, Sync.com
- Google Drive for desktop. Phones cannot use it this way: if a phone should sync too, use Google Drive (direct) on every device instead.
- Syncthing (no cloud at all: your devices sync with each other directly)
- The Nextcloud or ownCloud desktop client
- Any other folder that is kept in sync, or a network share

Keep the folder **available offline** ("Always keep on this device" in OneDrive, "Available offline" in Dropbox). Otherwise the cloud app may not download the newest file before NEFORUM reads it.

**A cloud app on your iPhone, iPad or Android phone.** Pick a location in the system file picker (the Files app on iPhone and iPad), and the cloud app does the syncing. How well this works depends on the cloud app, not on NEFORUM:

- **Choose folder**: NEFORUM keeps `NEFORUM.neforumsync` in the folder. Works with iCloud Drive, Dropbox and On My iPhone, and should work with the Nextcloud app (version 6 or newer). On Android it works with a folder that Syncthing-Fork or another sync app keeps in step. OneDrive, Box, MEGA, pCloud, Proton Drive and Synology Drive do not let other apps pick their folders: in the folder picker they look grayed out.
- **Choose the sync file**: pick the `NEFORUM.neforumsync` that your computer already made. This is for apps whose folders cannot be picked. OneDrive, Box and pCloud let NEFORUM open and save that one file, though the cloud app may take a while to upload changes. MEGA, Proton Drive and Sync.com are not recommended.
- **Create the sync file**: when the phone is your first device, save a new, empty sync file into the cloud app, and NEFORUM fills it in. If the cloud app asks whether to replace an existing file, cancel and use **Choose the sync file** instead.

On an iPhone or iPad you can also tap `NEFORUM.neforumsync` in the Files app, in iCloud Drive or On My iPhone. NEFORUM opens **Settings > Sync** with that file already chosen; just add the passphrase. Files inside other cloud apps keep that app's own icon and do not open NEFORUM: the cloud app decides that, not NEFORUM.

Install the cloud app and sign in first. On an iPhone, if the app is missing from the picker, open the Files app, tap **Browse**, then **⋯ > Edit**, and turn it on.

NEFORUM keeps access to what you picked after a restart. On iPhone and iPad it asks the cloud app for the newest file before every read, and hands over every write for upload. When you turn sync on, NEFORUM checks that it may change files there, without touching the sync file.

**WebDAV** (computers, iPhone, iPad and Android). NEFORUM talks to the server itself.

- Nextcloud and ownCloud, Koofr, pCloud, Infomaniak kDrive, Fastmail Files
- A Hetzner Storage Box
- A Synology or QNAP NAS
- Any other WebDAV server

Use an **app password** wherever the service offers one.

**S3-compatible object storage** (computers, iPhone, iPad and Android). NEFORUM talks to the bucket itself.

- Amazon S3, Cloudflare R2, Backblaze B2, Wasabi, IDrive e2, Scaleway, DigitalOcean Spaces, Hetzner Object Storage, Storj
- MinIO
- Any other S3-compatible store

Use a private bucket and a key that can only read and write that bucket.

Every device must use the same storage and the same file. For example: your PC, your iPhone and your Android phone all use **Google Drive (direct)** with the same Client ID; or your PC syncs a Dropbox folder and your iPhone picks the same folder in the Files app.
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

If a phone's background task cannot reach the sync location, it goes by what the last sync saw.

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

**On iPhone or iPad, tapping the sync file in Google Drive does nothing**
Google Drive's app did not hand the file over. Its Privacy Screen setting, a file that is not downloaded yet, or a stuck Google Drive app can all cause this. Use **Google Drive (direct)** instead, on every device. If you want to try the picker again: in Google Drive's settings, turn off Privacy Screen; mark the file **Available offline**; and restart the phone.

**"The Google sign-in expired or was revoked"**
Sign in again in **Settings > Sync > Change…**. If this happens every week, the Google Cloud app is still in Testing: click **Publish app** under Audience. If Google refuses the sign-in with "Access blocked" or a message that the app is being tested, add your Google address under **Audience > Test users**.
**On a Mac, iPhone or iPad, sync stopped after moving or renaming the folder**
Choose **Change…** and pick the folder again.

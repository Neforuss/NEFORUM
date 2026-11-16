# Sync between devices

Sync keeps your accounts, their keys, your posts and your settings the same on all your computers and phones. It works through **one encrypted file** that sits in storage you already use, such as a cloud drive. There is no NEFORUM server and no NEFORUM account, and your storage provider only ever sees an encrypted file.

## Steps: On your first device

1. Go to **Settings > Sync > Set up…** and pick your storage (see "Where the file can live" under How it works).
   - For **Google Drive (direct)**, do "Steps: Google Drive (direct)" below first.
2. Choose the folder, or fill in the WebDAV address or the S3 bucket and key.
3. Choose a **sync passphrase**. You can use **Generate** for a random one.
   - Write it down or keep it in your password manager. Without it, the file cannot be opened by you or by anyone else, and there is no recovery.
4. Choose **Turn on sync**. NEFORUM creates `NEFORUM.neforumsync` and puts everything in it.

## Steps: On each other device

1. Go to **Settings > Sync > Set up…** and pick the **same storage**.
   - On a new install, NEFORUM asks this when it first starts: "Do you already use NEFORUM on another device?" Pick your storage there to go straight to this step, or choose **No, I'm new to NEFORUM**. It asks only once on each device.
2. Choose the same folder or file, or fill in the same WebDAV address or S3 bucket and key.
3. Enter the **same passphrase**.
   - A code like `K7QF-MZ3D-W9TB-XC4N-P2RV-H8LG` can be typed in small letters and without the dashes: NEFORUM writes it in capitals and adds the dashes as you type. Any other passphrase is kept exactly as you type it.
4. Choose **Turn on sync**. NEFORUM opens the existing file and shows what joining will do, before it changes anything. For example: "This device gets 16 accounts, 2 media hosts and 41 settings from DESKTOP-X (Windows)", or "This device's setup will be used".
5. Choose **Join**.
   - To keep the other side's setup instead, choose **Use this device's setup instead** (or **Use the sync file's setup instead**). NEFORUM shows what that would do, and you confirm again.
6. Optional: check that the accounts arrived set up the same way. On both devices, go to **Accounts** and open **Connection** on an account card. It shows the account's server, your own app or client ID, its Page, board or channel, when the sign-in runs out, and which keys the device holds, marked **Synced**. **Copy setup** (one account) or **Copy all setups** (top of the page) puts this in your clipboard to compare. Keys, passwords and tokens are never shown or copied.

## Steps: Google Drive (direct)

Google Drive (direct) needs your own Google Cloud project. You set it up once, the same way as for NEFORUM's YouTube connection, and you can reuse that project.

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project, or open the one you use for YouTube.
2. **APIs & Services > Library**: enable the **Google Drive API**.
3. **OAuth consent screen** (Google Auth Platform): choose **External** and fill in the app name and your email.
4. Under **Data access**, add the scope `.../auth/drive.file`. This scope only lets NEFORUM see files it made itself.
5. **Audience > Test users**: click **Add users** and add **your own Google address**.
   - Add every Google account you will sign in with on any of your devices. That is the account whose Drive should hold the sync file. If an account is not on this list, Google refuses its sign-in.
   - This Google Cloud app is only for you. You don't share it, and nobody else uses your Client ID.
6. Optional: also under **Audience**, click **Publish app**.
   - While an app is in "Testing", Google ends its sign-ins after 7 days, and NEFORUM asks you to sign in again. With only the `drive.file` scope, publishing needs no review from Google.
7. **Clients > Create client**, type **Desktop app**.
8. Copy the **Client ID** and **Client secret**.
9. In NEFORUM, go to **Settings > Sync > Set up > Google Drive (direct)** and paste them.
10. Sign in with the Google account you added as a test user.
11. Do this on every device with the same Client ID, secret and passphrase.

## Steps: Turn sync off

1. Go to **Settings > Sync > Turn off**. This device keeps everything it has and stops using the file. The file and your other devices are not changed.

## How it works

Like KeePassXC, NEFORUM keeps one encrypted file in storage you already use, and every device reads and writes that file.

Every device must use the same storage and the same file. For example: your PC, your iPhone and your Android phone all use **Google Drive (direct)** with the same Client ID; or your PC syncs a Dropbox folder and your iPhone picks the same folder in the Files app.

### A device's first sync

The first time a device syncs with a file that already exists:

- **Nothing is deleted.** Anything that only one side has, such as an account, its keys or a post, is kept and copied to the other side. Media hosts work a little differently because they have two slots; see the last point.
- **The setup with the most accounts wins.** Sometimes the device and the file hold different versions of the same thing: a setting, an account's details or a media host. Then the side with more accounts keeps its version. An account that the file holds twice counts once.
  - If both sides have the same number of accounts, the side whose oldest account was connected first wins.
  - If that is a tie too, the file wins, because your other devices already use it.
  - You see which side wins before you join, and you can pick the other one.
- **One account, not two.** Mastodon, Pixelfed, TikTok and most hand-off accounts (where you press Post yourself) get a different id on each device, so one account connected on two devices can arrive twice. NEFORUM turns the two copies into one account. It keeps the newer sign-in (its details and keys together) and moves posts and default targets to it. See "When accounts are merged" below.
- **Media hosts, slot by slot.** Each side has a main slot and a fallback slot. The winning side keeps its hosts in their slots. A host from the other side goes into an empty slot, so it is kept. A device without a media host never removes another device's host. A host from the other side is replaced only when the winning side uses both slots, and NEFORUM names that host before you join.

After the first sync, each change travels on its own. That includes a setting you put back to its default and a media host you remove.

### When accounts are merged

NEFORUM merges two copies of one account only in these cases:

- **Mastodon, Pixelfed and TikTok accounts** with the same id on their server (or the same TikTok user for the same app). This happens on any sync and on any device, including devices that joined long ago. That way, two devices that join at the same moment, or a sync that was interrupted, still end up with one account.
- **Other accounts with a made-up id**, matched by their handle, ignoring capital letters and a leading @. This happens only when one of the two copies is new to the sync file in that sync. Two copies that were both in the file already are never merged.
- **Hand-off accounts**, only on a device's first sync. The hand-off made on that device must have the same name or handle as one in the sync file, on the same site. WordPress, Ghost and WriteFreely blogs are told apart by their whole address, path included.

NEFORUM never merges:

- two accounts whose ids come from the accounts themselves (X, Bluesky, YouTube, Reddit, a WordPress blog and most others);
- accounts on two different servers or sites;
- accounts with two different handles.

Before the first sync, the dry run (the summary of what joining will do) lists the merges it will make.

After a merge, the old copy and its keys stay on the device until the sync file holds the merged account. A post that still names the old copy, such as a draft you were editing, moves to the merged account on the next sync. NEFORUM keeps the link from the old copy to the merged account for 90 days. A device with NEFORUM 1.3.4 leaves such a post as it is and does not remove the link from the sync file; the next device with 1.3.5 to sync moves the post.

### Where the file can live

**Google Drive (direct)** (computers, iPhone, iPad and Android). NEFORUM talks to Google Drive itself and keeps the file in a **NEFORUM Sync** folder in your My Drive. Use this to sync through Google Drive on a phone or tablet. Google Drive's iPhone and iPad app does not let other apps pick its folders, and it often does not hand files over to them. **Every device must use Google Drive (direct)**, your computers too, because NEFORUM cannot see a file that Google Drive for desktop put in another folder.

**A cloud app on your computer.** NEFORUM writes the file into a folder; your cloud app does the syncing.

- OneDrive, Dropbox, iCloud Drive, Box Drive, MEGA, pCloud Drive, Proton Drive, Sync.com
- Google Drive for desktop. Phones cannot use it this way: if a phone should sync too, use Google Drive (direct) on every device instead.
- Syncthing (no cloud at all: your devices sync with each other directly)
- The Nextcloud or ownCloud desktop client
- Any other folder that is kept in sync, or a network share

Keep the folder **available offline** ("Always keep on this device" in OneDrive, "Available offline" in Dropbox). Otherwise the cloud app may not download the newest file before NEFORUM reads it.

**A cloud app on your iPhone, iPad or Android phone.** Pick a location in the system file picker (the Files app on iPhone and iPad), and the cloud app does the syncing. How well this works depends on the cloud app rather than on NEFORUM. There are three ways to pick:

- **Choose folder**: NEFORUM keeps `NEFORUM.neforumsync` in the folder. This works with iCloud Drive, Dropbox and On My iPhone, and should work with the Nextcloud app (version 6 or newer). On Android it works with a folder that Syncthing-Fork or another sync app keeps in step. OneDrive, Box, MEGA, pCloud, Proton Drive and Synology Drive do not let other apps pick their folders, so they look grayed out in the folder picker.
- **Choose the sync file**: pick the `NEFORUM.neforumsync` that your computer already made. This is for apps whose folders cannot be picked. OneDrive, Box and pCloud let NEFORUM open and save that one file, though the cloud app may take a while to upload changes. MEGA, Proton Drive and Sync.com are not recommended.
- **Create the sync file**: when the phone is your first device, save a new, empty sync file into the cloud app, and NEFORUM fills it in. If the cloud app asks whether to replace an existing file, cancel and use **Choose the sync file** instead.

On an iPhone or iPad you can also tap `NEFORUM.neforumsync` in the Files app, in iCloud Drive or On My iPhone. NEFORUM opens **Settings > Sync** with that file already chosen, and you only add the passphrase. Files inside other cloud apps keep that app's own icon and do not open NEFORUM, because the cloud app controls what happens when you tap its files.

Install the cloud app and sign in first. On an iPhone, if the app is missing from the picker, open the Files app, tap **Browse**, then **⋯ > Edit**, and turn it on.

NEFORUM keeps access to what you picked after a restart. On iPhone and iPad it asks the cloud app for the newest file before every read, and hands every write to the cloud app to upload. When you turn sync on, NEFORUM checks that it is allowed to change files there, without touching the sync file.

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

### What syncs

| Synced | |
|---|---|
| Accounts and their keys | Yes |
| Drafts, scheduled posts and history | Yes |
| Settings (theme, text cards, photo fitting, posting rules, default targets, how the browser extension posts) | Yes |
| Media hosts (main and fallback) and their keys | Yes |
| Photos and videos | No: they stay on the device they were added on |
| Fonts | No: each device keeps its own font files. A text card or caption style that names a font does sync. A device without that font draws the default font, never holds a post back for it, and offers one-tap download if the font came from the font list |
| Device settings (start at sign-in, tray, the browser extension being on, automatic posting, zoom and text size, background picture, update checks, font downloads, Sync itself) | No |
| An account's last error | No: another device may have no problem with that account |

NEFORUM syncs when it starts, every five minutes, and a few seconds after you change something. You can also choose **Sync now** at any time.

## When two devices change the same thing

Each account, post and setting merges on its own, so changes on different things never clash. When the same thing was changed on two devices before they synced:

- A post that went out, was tried (even if it failed or was cancelled) or is being published beats another device's version that has not got that far, even a newer edit. This keeps a post from going out twice. Between two versions that got equally far, the newer edit wins, by each device's clock.
- An account's sign-in is the developer app or server it is connected through, plus its ids and its keys. Between devices with 1.3.5, the sign-in travels as one piece, also when a sync arrives while NEFORUM is posting or renewing that sign-in. There is one rare exception, described at the end of this point.
  - Suppose you reconnect the account through another app or server on one device while another device renews the old sign-in. The most recent connection wins, even though the renewed keys expire later, so the new app is never paired with the old keys, or the other way round.
  - When both devices use the same app with the same settings, the keys renewed last win, because those are the ones the network still accepts.
  - A device with 1.3.4 can break this; see the limitation below.
  - The rare exception, inherited from 1.3.4: if another device renewed the old sign-in since the last sync, a sync that runs in the very instant you finish reconnecting the account can still pair the new app with the old keys. If the account asks to be reconnected right after you reconnected it, reconnect it once more.
- NEFORUM does not record when you changed a setting, a media host, or your own details on an account (switched on or off, renamed, quotas). When the same one was changed on two devices before either synced, the device that syncs second keeps its own version, even when the other change was made later. This assumes both devices' clocks are right: a device whose clock runs ahead can keep its version even when it syncs first. To be sure a change sticks, make it on one device and let it sync before you change the same thing on another.
- An edit beats a deletion, so nothing you were working on disappears.

Cloud apps sometimes keep two copies when two devices save at the same moment, for example "NEFORUM (conflicted copy).neforumsync". NEFORUM merges such copies into the main file and then removes them.

**Known limitation: devices with NEFORUM 1.3.4 or older.** Update every synced device to 1.3.5 or later. An older device:

- does not send a setting you put back to its default;
- does not take the settings that 1.3.5 added to sync (how the browser extension posts), and removes them from the sync file;
- asks "which data should win" instead of showing what joining will do;
- keeps the keys that expire later without looking at the account: after you reconnect an account through another app on a 1.3.5 device, a 1.3.4 device that renewed the old sign-in meanwhile can pair the new app with the old keys, on every device. Reconnect the account again on a 1.3.5 device to fix it.

When an older device removes a setting from the file, the devices with 1.3.5 keep their own value. A device that joins after that keeps its own value too, unless its setup wins. On their next sync, the devices already syncing put their value back into the file once, so the new device gets it.

**Known limitation: a device with a newer NEFORUM.** Something only a newer version knows, such as a post in a state this version does not have, stays in the sync file for the devices that know it, but is not stored on this device. Before a first sync, the dry run may still count it among what arrives.

## X and Tumblr

X and Tumblr give out a new sign-in key every time one is renewed, and the old key stops working. Normally that means an account copied to two devices stays connected on only one of them. With Sync, NEFORUM handles it three ways:

1. **One renewer at a time.** The device that renews first marks the account as being renewed in the sync file. The other devices wait for it.
2. **The newest keys travel.** The renewed keys go into the file right away, and the other devices use them instead of renewing themselves.
3. **Retry after a refusal.** If X or Tumblr refuses a device's keys because another device renewed a moment earlier, NEFORUM reads the file again and retries with the newer keys. With a cloud app's folder, the new file can take a minute to arrive, so NEFORUM tries again a little later instead of asking you to reconnect.

Each device also keeps its own note of when each sign-in ends, so a closed card can show the date with no keychain prompt. That note (`sign-in-status.json`), and the record of which warnings it already gave (`sign-in-warnings.json`), stay on the device: the dates themselves travel with the keys. See [How long each sign-in lasts](sign-in-lifetimes.md).

You can avoid renewals on Tumblr by connecting with **OAuth 1.0a keys**, which are not renewed. X offers the same keys until **31 January 2027**, when it stops accepting them. See "Stay connected on several devices" in the [X](platforms/x.md) and [Tumblr](platforms/tumblr.md) guides. TikTok, DeviantArt and Pixelfed also replace their keys on renewal and take the same turns.

## Scheduled posts

**A scheduled post is published by the device it was scheduled on**, because that device has its photos and videos. Your other devices show the post but leave it alone.

If that device stops syncing (it is switched off, or NEFORUM is closed) and the post is more than 30 minutes overdue, another device publishes it instead. It only does so if it has all of the post's photos and videos, so any of your devices can pick up a text-only post.

If a phone's background task cannot reach the sync location, it decides from what the last sync saw.

Platforms that hold scheduled posts themselves (see **Settings > Scheduling**) publish on time either way.

**Known limitation: a different time per network and NEFORUM 1.2.** NEFORUM 1.2 does not know about a different time per network. A device with 1.2 can end up publishing such a post, because it picked up an overdue post or because the post was scheduled there. It then sends the post to every network at the earliest of the times. Update every synced device to 1.3 or later before you use **Different time per network**.

## Safety

- The file uses the same encryption as **Move to another device**. The passphrase is stretched with Argon2id (19 MiB, 2 passes), which makes guessing it slow, and everything is encrypted with AES-256-GCM. If the file is changed in any way outside NEFORUM, it can no longer be opened, so NEFORUM never reads wrong data from it.
- The passphrase and your storage password stay in this device's system keychain.
- NEFORUM never makes the file public. It needs no sharing link, and a private bucket is enough.
- To change the passphrase, turn Sync off on every device, delete `NEFORUM.neforumsync`, then set it up again with the new passphrase.

## Troubleshooting

**"The sync passphrase does not open the sync file"**
Use the passphrase you chose on your first device. If it looks like a code (letters and digits only, 24 at most) and you set it in small letters before NEFORUM 1.4.3, type it in small letters the way you set it. NEFORUM tries it that way too.

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

# Media hosts: giving Instagram, Threads and TikTok a public link

This guide sets up a *media host*: a place where NEFORUM puts a photo or video for a short time, so that platforms which only accept a **public web address** of the file can download it. **Litterbox** works with no setup; for regular posting, set up a bucket you own.

## Steps

1. Open **Settings > Media hosting**.
2. Pick a host (see "Which one should I pick?" under How it works).
   - **Litterbox is the zero-setup start:** pick it and you can post right away. Optional: **Keep files for** = `1h` (default), `12h`, `24h` or `72h`.
   - For regular posting, set up your own **bucket** (Backblaze B2 or Cloudflare R2, both have free tiers): see "Steps: S3-compatible bucket".
3. Fill in the fields.
4. Press **Test connection**. What the test does depends on the host, and the result says what was tested.
5. Optional: once a main host is saved, add a **fallback host** from a different provider (see [Fallback host](#fallback-host)).

## Steps: S3-compatible bucket

### Backblaze B2 (good free tier, no card needed)

1. Sign up at backblaze.com > **B2 Cloud Storage** > **Create a Bucket**.
2. Set *Files in Bucket* to **Public**.
3. Note the bucket's **Endpoint**, for example `s3.us-west-004.backblazeb2.com`.
4. **Application Keys** > **Add a New Application Key**. Allow access to this bucket only, with *Read and Write*.
5. Copy the **keyID** and the **applicationKey** (it is shown only once).
6. In NEFORUM: Endpoint `https://s3.us-west-004.backblazeb2.com`, Bucket = your bucket name, keys from step 5, Public base URL `https://<bucket>.s3.us-west-004.backblazeb2.com`.

### Cloudflare R2

1. Cloudflare dashboard > **R2**. Enabling R2 goes through a subscription checkout and needs a payment method on file, even for the free tier. (Backblaze B2 above needs no card.)
2. **Create bucket**, for example `my-post-media`. Use it only for NEFORUM.
3. Decide how platforms reach the files:
   - **Private bucket + signed links** (simplest): change nothing under *Public access* and leave NEFORUM's *Public base URL* empty. The bucket stays private and you don't need a domain or any DNS change. Meta does not document whether it accepts signed links, so this is **unverified**: post one real Instagram photo to check.
   - **Public custom domain**: if Instagram can't fetch the file (error 9004 / 2207052), open the bucket's **Settings > Public access** and connect a custom domain such as `media.example.com` (the domain must be on Cloudflare). Then put `https://media.example.com` in *Public base URL*. The `r2.dev` URL also works, but Cloudflare says it is rate-limited and meant for development only.
4. API token: **R2** > **Manage API Tokens** (on the R2 overview page, under *Account Details*) > **Create Account API token**.
5. Permissions: **Object Read & Write**. Under the bucket choice pick **Apply to specific buckets only** and select your bucket. Create it.
6. The next page shows three values: a **Token value**, an **Access Key ID** and a **Secret Access Key**. Copy the **Access Key ID** and the **Secret Access Key**, not the Token value.
   - Copy the secret now; Cloudflare shows it only once.
7. Endpoint: on the same R2 overview page, *Account Details* shows the **S3 API** address next to **Manage API Tokens**. It looks like `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`. Use it without a bucket name at the end.
8. Safety net: bucket > **Settings** > **Object Lifecycle Rules** > **Add rule**: delete objects older than **1 day**, and abort incomplete multipart uploads after **1 day**.
   - Leave the prefix empty when the bucket is only for NEFORUM (or enter your *Folder in the bucket*, e.g. `neforum/`).
9. In NEFORUM: Endpoint = the S3 API address from step 7, Region empty (= `auto`), Bucket = your bucket name, Access key ID and Secret access key from step 6, Public base URL empty (signed links) or your custom domain.
10. Press **Test connection**.

### Amazon S3

1. Create a bucket in the region you want.
2. To use public links: turn off *Block public access* and add a bucket policy that allows `s3:GetObject` on `arn:aws:s3:::<bucket>/*`.
3. Create an IAM user with an access key and a policy that allows `s3:PutObject` and `s3:DeleteObject` on that bucket only.
4. In NEFORUM: Endpoint `https://s3.<region>.amazonaws.com`, Public base URL `https://<bucket>.s3.<region>.amazonaws.com`.

### MinIO (self-hosted)

1. Make the bucket readable by anyone: `mc anonymous set download ALIAS/BUCKET`.
2. Make sure the server is reachable from the internet over HTTPS. Instagram can't fetch from your home network's private address.
3. In NEFORUM: Endpoint = your server address, Region empty, Addressing style `path`, Public base URL `https://<host>/<bucket>`.

## Steps: Nextcloud, ownCloud, WebDAV

### Nextcloud / ownCloud

1. Nextcloud > avatar > **Settings > Security > Devices & sessions** > enter "NEFORUM" > **Create new app password**.
2. Copy the password.
3. In Files, open **Files settings** (bottom left) and copy the **WebDAV** address.
   - It looks like `https://cloud.example.com/remote.php/dav/files/<user>/`.
4. Add a folder name at the end, for example `.../NEFORUM`. NEFORUM creates that folder if it doesn't exist.
5. In NEFORUM: WebDAV folder URL = that address, Username = your user ID, App password = the one from step 2. Leave *Public URL template* empty.

### Other WebDAV servers

For Apache mod_dav, nginx, rclone serve, a NAS, ...:

1. Fill in *Public URL template* with the public web address of the same folder, putting `{name}` where the file name goes. For example, `https://files.example.com/neforum/{name}`.

## Steps: My own links

1. Put each file online yourself, under the same file name it has on your device.
2. Enter the **Link pattern**: the public `https://` address of that folder with `{name}` where the file name goes, for example `https://example.com/media/{name}`.

## Steps: Catbox with an account

To let NEFORUM delete Catbox files after posting:

1. Create a free catbox.moe account.
2. Paste the **userhash** from your account page into *Account hash (userhash)*.

## How it works

Some platforms do not accept a photo or video from your device. Instead they ask for a **public web address** of the file and download it themselves:

- **Instagram** and **Threads** always work this way. Meta's docs: "We cURL media used in publishing attempts, so the media must be hosted on a publicly accessible server at the time of the attempt."
- **TikTok** works this way only in its `PULL_FROM_URL` mode. NEFORUM normally uploads to TikTok directly, so you usually don't need a host for TikTok.

NEFORUM uploads the file, gives the link to the platform, waits until the platform says it has the media, and then deletes the file wherever the host allows it.

What the link has to do (checked against Meta's and TikTok's docs, plus reports from developers in 2025-2026):

- open the file itself: HTTP 200, the right `Content-Type` (`image/jpeg`, `image/png`, `video/mp4`), no HTML page, no login;
- no redirects (TikTok rejects any 3xx; for Meta they are unreliable);
- stay reachable until the platform has finished downloading. That is a few seconds for photos, a few minutes for videos, and up to 1 hour for TikTok.

### Which one should I pick?

| Host | Account needed | Cost | Max file | Deleted after posting | Good for |
|---|---|---|---|---|---|
| **Litterbox** (default) | no | free | 1 GB | expires by itself (1 h to 3 days) | trying things out, occasional posting |
| **S3-compatible bucket** | yes (AWS, Cloudflare R2, Backblaze B2, MinIO) | free tiers available | 5 GB per upload | yes | regular use, most reliable |
| **Nextcloud / WebDAV** | your own server | free | set by your server | yes (Nextcloud) | people who already run Nextcloud |
| **Catbox** | optional | free | 200 MB (GIF 20 MB) | only with an account hash | permanent links |
| **My own links** | n/a | n/a | n/a | n/a (you manage the files) | you already host your files |

Litterbox is run by one volunteer and is sometimes down or refuses uploads for a while; a bucket you own doesn't depend on anyone else's server. You can also keep Litterbox and add a bucket as the [fallback host](#fallback-host).

### Test connection

| Host | What **Test connection** does |
|---|---|
| Litterbox | uploads a tiny text file (23 bytes) set to expire after 1 hour, so it deletes itself |
| Catbox with an account hash | uploads a tiny text file and deletes it again with your account hash (this also checks the hash) |
| Catbox without an account hash | only checks that catbox.moe answers. Uploads are **not** tested, because an anonymous test file could never be deleted |
| S3-compatible bucket, Nextcloud / WebDAV | uploads a tiny text file, checks that its link opens without a login, and deletes the file again |
| My own links | nothing to test (NEFORUM uploads nothing); open one of your links in a browser |

### When an upload fails

If the host has a temporary problem (an HTTP 5xx answer such as 500 or 503, a timeout or a dropped connection), NEFORUM waits a few seconds and tries once more. If that fails too, the error says in plain words what happened and whose side the problem is on, for example: *"Litterbox couldn't store the file: its server answered HTTP 500 (Internal Server Error). This is a problem on Litterbox's side; try again later or choose another media host in Settings."* A 4xx answer (the host turned the file or your settings down) is not retried, because sending the same thing again won't help.

## Fallback host

Once a main host is saved, **Settings > Media hosting** offers an optional **fallback host**. When the main host can't store a file, after its own retry, NEFORUM uploads the file to the fallback instead, so the post still goes out. That covers outages (Litterbox answering HTTP 500), settings problems and files larger than the main host accepts (those go straight to the fallback).

- **Pick a different provider.** Litterbox and Catbox are run by the same people, so an outage often hits both. A good pair is Litterbox as the main host with your own bucket as the fallback, or the other way round.
- **You're told when it steps in.** The Media hosting section shows the last time the fallback was used this session, and why the main host failed.
- **If both fail**, the post's error explains both problems. It counts as temporary (try again later) when either host only had an outage.
- **Clean-up** reaches the host that stored the file, even when both are the same kind (for example two buckets).
- **Removing the main host** makes the fallback the main host.
- **Test connection** under the fallback tests the fallback only.

## Litterbox and Catbox

Both are free services run by one volunteer at catbox.moe. They come with no guarantee, and files go to a server you do not control. Don't upload anything private.

**Litterbox** (temporary, default)

- Nothing to set up. Optional: **Keep files for** = `1h` (default), `12h`, `24h` or `72h`. Those are the only values Litterbox accepts.
- If a platform needs the file for longer, NEFORUM picks a longer time on its own. Instagram and Threads videos use 24 h.
- Up to 1 GB per file ("Temporary uploads up to 1 GB are allowed.").
- Files can't be deleted early. They disappear when the time is up.
- **Test connection** really uploads: a 23-byte text file kept for 1 hour (whatever *Keep files for* says), which then expires by itself.

**Catbox** (permanent)

- Up to 200 MB per file. GIFs over 20 MB are rejected (upload a video instead). `.exe .scr .cpl .doc* .jar` files are banned.
- Anonymous uploads are **never deleted by NEFORUM**: the API can't delete them. Catbox removes them after 2 years without views.
- To let NEFORUM delete files after posting, add an account hash (see "Steps: Catbox with an account"). Files tied to an account are permanent until deleted.
- **Test connection** with an account hash uploads a tiny file and deletes it again. Without one it only checks that catbox.moe answers and says that uploads were not tested, so no permanent anonymous test file is left behind.
- Catbox's FAQ says: "You cannot use Catbox for commercial services without prior approval." Use it for your own posts, not for a business.

## S3-compatible bucket

The most reliable option. Files go into a storage bucket you own, uploaded with your own keys, and are deleted after posting. NEFORUM signs requests itself (AWS Signature V4), so no extra server is involved.

### Fields

| Field | Example | Notes |
|---|---|---|
| Endpoint | `https://s3.us-west-004.backblazeb2.com` | the S3 API address (see the steps for each provider) |
| Region | `us-west-004` | leave empty to guess it: R2 = `auto`, AWS and B2 from the endpoint (also `s3.dualstack.<region>`), MinIO = `us-east-1` |
| Bucket | `my-post-media` | |
| Access key ID | | B2: "keyID" |
| Secret access key | | B2: "applicationKey"; stored in your device's keychain |
| Public base URL | `https://my-post-media.s3.us-west-004.backblazeb2.com` | where anyone can read the bucket; leave empty for a private bucket (see below) |
| Folder in the bucket | `neforum/` | optional |
| Addressing style | `auto` | `path` = `endpoint/bucket/key`, `virtual` = `bucket.endpoint/key` |

### Public or private bucket?

- *Public-read bucket + Public base URL* (recommended): links are plain and never expire.
- *Private bucket, Public base URL empty*: NEFORUM hands out a **signed link** that works for as long as the platform needs it, at most 7 days (the S3 limit). Nothing in the bucket is public and no domain or DNS setup is needed. Meta does not document whether it accepts these. Developers report that they work as long as the link has not expired. Use a public bucket if you see "media could not be fetched" (Instagram error 9004 / 2207052).

**Safety net:** add a *lifecycle rule* to the bucket that deletes objects in `neforum/` after 1 day. Then nothing is left behind if NEFORUM is closed in the middle of posting.

### Prices

- Backblaze B2, as of October 2026: the first 10 GB of storage are always free, and downloads are free up to 3 times your average monthly storage. B2 does not support per-file permissions, so the whole bucket is public.
- Cloudflare R2 free tier, as of October 2026: 10 GB-month of storage, 1 million writes and 10 million reads per month, free egress.

## Nextcloud and WebDAV

For each file, NEFORUM uploads it, creates a read-only **public link** that expires the day after it is needed, and passes `<link>/download` to the platform. After posting, NEFORUM removes the link and the file.

Known issue: Nextcloud 31 and 32 redirect `/s/<token>/download` to `/public.php/dav/files/<token>/`. If Instagram reports that the media could not be fetched, set **Nextcloud link style** to `dav`. NEFORUM then uses the final address directly. Public link sharing must be enabled by your administrator, and links must not require a password.

Other WebDAV servers: NEFORUM can upload but cannot create links, which is why they need the *Public URL template*.

## My own links

NEFORUM uploads nothing. A photo called `IMG_1234.jpg` is handed to the platform as `https://example.com/media/IMG_1234.jpg` (spaces and other special characters are URL-encoded). The link must open the file directly: no web page, no login, no redirect. Google Drive and Dropbox share links do **not** work.

## Limits

- On the web build, browsers block uploads to buckets and servers that are not configured for cross-origin (CORS) requests. The desktop and mobile apps are not affected.
- NEFORUM holds each file in memory while it uploads it. Very large videos (several GB) may fail on phones.
- Free third-party hosts (Litterbox, Catbox) can be slow or down. NEFORUM retries a failed upload once; if posting still fails, or Instagram says "media could not be fetched", try again later or switch to your own bucket.

## Sources

- Instagram content publishing: https://developers.facebook.com/docs/instagram-platform/content-publishing
- Instagram error codes: https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/error-codes
- Threads posts: https://developers.facebook.com/docs/threads/posts
- TikTok media transfer guide: https://developers.tiktok.com/doc/content-posting-api-media-transfer-guide
- AWS Signature V4 (header): https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
- AWS Signature V4 (query string): https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
- AWS presigned uploads: https://docs.aws.amazon.com/AmazonS3/latest/userguide/PresignedUrlUploadObject.html
- Cloudflare R2 presigned URLs: https://developers.cloudflare.com/r2/api/s3/presigned-urls/
- Cloudflare R2 public buckets: https://developers.cloudflare.com/r2/buckets/public-buckets/
- Cloudflare R2 pricing: https://developers.cloudflare.com/r2/pricing/
- Cloudflare R2 API tokens: https://developers.cloudflare.com/r2/api/tokens/
- Cloudflare R2 object lifecycles: https://developers.cloudflare.com/r2/buckets/object-lifecycles/
- Backblaze B2 S3-compatible API: https://www.backblaze.com/docs/cloud-storage-s3-compatible-api
- Backblaze B2 pricing: https://www.backblaze.com/cloud-storage/pricing
- MinIO `mc anonymous set`: https://docs.min.io/community/minio-object-store/reference/minio-mc/mc-anonymous-set.html
- Nextcloud OCS Share API: https://docs.nextcloud.com/server/latest/developer_manual/client_apis/OCS/ocs-share-api.html
- Nextcloud sharing (user manual): https://docs.nextcloud.com/server/latest/user_manual/en/files/sharing.html
- Catbox API: https://catbox.moe/tools.php
- Catbox FAQ: https://catbox.moe/faq.php
- Litterbox API: https://litterbox.catbox.moe/tools.php

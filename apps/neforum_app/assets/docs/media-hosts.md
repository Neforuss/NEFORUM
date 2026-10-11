# Media hosts: giving Instagram, Threads and TikTok a public link

Some platforms do not accept a photo or video from your device. Instead they
ask for a **public web address** of the file and download it themselves:

- **Instagram** and **Threads** always work this way. Meta's docs: "We cURL media
  used in publishing attempts, so the media must be hosted on a publicly
  accessible server at the time of the attempt."
- **TikTok** works this way only in its `PULL_FROM_URL` mode. NEFORUM normally
  uploads to TikTok directly, so you usually don't need a host for TikTok.

A *media host* is where NEFORUM puts the file for a short time so the platform
can fetch it. NEFORUM uploads the file, gives the link to the platform, waits
until the platform says it has the media, and then deletes the file wherever
the host allows it.

What the link has to do (checked against Meta's and TikTok's docs, plus reports
from developers in 2025-2026):

- open the file itself: HTTP 200, the right `Content-Type` (`image/jpeg`,
  `image/png`, `video/mp4`), no HTML page, no login;
- no redirects (TikTok rejects any 3xx; for Meta they are unreliable);
- stay reachable until the platform has finished downloading. That is a few
  seconds for photos, a few minutes for videos, and up to 1 hour for TikTok.

## Which one should I pick?

| Host | Account needed | Cost | Max file | Deleted after posting | Good for |
|---|---|---|---|---|---|
| **Litterbox** (default) | no | free | 1 GB | expires by itself (1 h to 3 days) | trying things out, occasional posting |
| **S3-compatible bucket** | yes (AWS, Cloudflare R2, Backblaze B2, MinIO) | free tiers available | 5 GB per upload | yes | regular use, most reliable |
| **Nextcloud / WebDAV** | your own server | free | set by your server | yes (Nextcloud) | people who already run Nextcloud |
| **Catbox** | optional | free | 200 MB (GIF 20 MB) | only with an account hash | permanent links |
| **My own links** | n/a | n/a | n/a | n/a (you manage the files) | you already host your files |

Settings > Media host > pick one > fill in the fields > **Test**. For the
bucket and WebDAV hosts the test uploads a tiny text file, checks the link and
deletes the file again.

## Litterbox and Catbox

Both are free services run by one volunteer at catbox.moe. They come with no
guarantee, and files go to a server you do not control. Don't upload anything
private.

**Litterbox** (temporary, default)

- Nothing to set up. Optional: **Keep files for** = `1h` (default), `12h`, `24h` or `72h`.
  Those are the only values Litterbox accepts.
- If a platform needs the file for longer, NEFORUM picks a longer time on its
  own. Instagram and Threads videos use 24 h.
- Up to 1 GB per file ("Temporary uploads up to 1 GB are allowed.").
- Files can't be deleted early. They disappear when the time is up.

**Catbox** (permanent)

- Up to 200 MB per file. GIFs over 20 MB are rejected (upload a video
  instead). `.exe .scr .cpl .doc* .jar` files are banned.
- Anonymous uploads are **never deleted by NEFORUM**: the API can't delete them.
  Catbox removes them after 2 years without views.
- To let NEFORUM delete files after posting, create a free catbox.moe account
  and paste the **userhash** from your account page into
  *Account hash (userhash)*. Files tied to an account are permanent until
  deleted.
- Catbox's FAQ says: "You cannot use Catbox for commercial services without
  prior approval." Use it for your own posts, not for a business.

## S3-compatible bucket

The most reliable option. Files go into a storage bucket you own, uploaded with
your own keys, and are deleted after posting. NEFORUM signs requests itself
(AWS Signature V4), so no extra server is involved.

### Fields

| Field | Example | Notes |
|---|---|---|
| Endpoint | `https://s3.us-west-004.backblazeb2.com` | the S3 API address (see below) |
| Region | `us-west-004` | leave empty to guess it: R2 = `auto`, MinIO = `us-east-1` |
| Bucket | `my-neforum-media` | |
| Access key ID | | B2: "keyID" |
| Secret access key | | B2: "applicationKey"; stored in your device's keychain |
| Public base URL | `https://my-neforum-media.s3.us-west-004.backblazeb2.com` | where anyone can read the bucket; leave empty for a private bucket (see below) |
| Folder in the bucket | `neforum/` | optional |
| Addressing style | `auto` | `path` = `endpoint/bucket/key`, `virtual` = `bucket.endpoint/key` |

**Public or private bucket?**

- *Public-read bucket + Public base URL* (recommended): links are plain and
  never expire.
- *Private bucket, Public base URL empty*: NEFORUM hands out a **signed link**
  that works for as long as the platform needs it, at most 7 days (the S3
  limit). Meta does not document whether it accepts these. Developers report
  that they work as long as the link has not expired. Use a public bucket if
  you see "media could not be fetched".

**Safety net:** add a *lifecycle rule* to the bucket that deletes objects in
`neforum/` after 1 day. Then nothing is left behind if NEFORUM is closed in the
middle of posting.

### Backblaze B2 (good free tier, no card needed)

1. Sign up at backblaze.com > **B2 Cloud Storage** > **Create a Bucket**. Set
   *Files in Bucket* to **Public**.
2. Note the bucket's **Endpoint**, for example `s3.us-west-004.backblazeb2.com`.
3. **Application Keys** > **Add a New Application Key**. Allow access to this
   bucket only, with *Read and Write*. Copy the **keyID** and the
   **applicationKey** (it is shown only once).
4. In NEFORUM: Endpoint `https://s3.us-west-004.backblazeb2.com`, Bucket = your
   bucket name, keys from step 3, Public base URL
   `https://<bucket>.s3.us-west-004.backblazeb2.com`.

Pricing as of October 2026: the first 10 GB of storage are always free, and
downloads are free up to 3 times your average monthly storage. B2 does not
support per-file permissions, so the whole bucket is public.

### Cloudflare R2

1. Cloudflare dashboard > **R2**. Enabling R2 goes through a subscription
   checkout and needs a payment method on file, even for the free tier.
2. **Create bucket**. Under **Settings > Public access**, connect a **custom
   domain** (recommended), or enable the `r2.dev` URL. Cloudflare says the
   `r2.dev` URL is rate-limited and meant for development only.
3. **Manage R2 API Tokens** > create a token with *Object Read & Write* on this
   bucket. Copy the **Access Key ID** and the **Secret Access Key**.
4. In NEFORUM: Endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`, Region
   empty (= `auto`), Public base URL = your custom domain or the `pub-....r2.dev`
   address.

Free tier as of October 2026: 10 GB-month of storage, 1 million writes and
10 million reads per month, free egress.

### Amazon S3

1. Create a bucket in the region you want. To use public links: turn off
   *Block public access* and add a bucket policy that allows `s3:GetObject` on
   `arn:aws:s3:::<bucket>/*`.
2. Create an IAM user with an access key and a policy that allows `s3:PutObject`
   and `s3:DeleteObject` on that bucket only.
3. In NEFORUM: Endpoint `https://s3.<region>.amazonaws.com`, Public base URL
   `https://<bucket>.s3.<region>.amazonaws.com`.

### MinIO (self-hosted)

1. Make the bucket readable by anyone: `mc anonymous set download ALIAS/BUCKET`.
2. The server must be reachable from the internet over HTTPS. Instagram can't
   fetch from your home network's private address.
3. In NEFORUM: Endpoint = your server address, Region empty, Addressing style
   `path`, Public base URL `https://<host>/<bucket>`.

## Nextcloud, ownCloud, WebDAV

**Nextcloud / ownCloud**

1. Nextcloud > avatar > **Settings > Security > Devices & sessions** > enter
   "NEFORUM" > **Create new app password**. Copy the password.
2. In Files, open **Files settings** (bottom left) and copy the **WebDAV**
   address. It looks like
   `https://cloud.example.com/remote.php/dav/files/<user>/`. Add a folder name
   at the end, for example `.../NEFORUM`. NEFORUM creates that folder if it
   doesn't exist.
3. In NEFORUM: WebDAV folder URL = that address, Username = your user ID,
   App password = the one from step 1. Leave *Public URL template* empty.

For each file, NEFORUM uploads it, creates a read-only **public link** that
expires the day after it is needed, and passes `<link>/download` to the
platform. After posting, NEFORUM removes the link and the file.

Known issue: Nextcloud 31 and 32 redirect `/s/<token>/download` to
`/public.php/dav/files/<token>/`. If Instagram reports that the media could not
be fetched, set **Nextcloud link style** to `dav`. NEFORUM then uses the final
address directly. Public link sharing must be enabled by your administrator,
and links must not require a password.

**Other WebDAV servers** (Apache mod_dav, nginx, rclone serve, a NAS, ...):
NEFORUM can upload but cannot create links. Fill in *Public URL template* with
the public web address of the same folder, putting `{name}` where the file name
goes. For example, `https://files.example.com/neforum/{name}`.

## My own links

NEFORUM uploads nothing. You put each file online yourself and paste its public
`https://` link. The link must open the file directly: no web page, no login,
no redirect. Google Drive and Dropbox share links do **not** work.

## Limitations

- On the web build, browsers block uploads to buckets and servers that are not
  configured for cross-origin (CORS) requests. The desktop and mobile apps are
  not affected.
- NEFORUM holds each file in memory while it uploads it. Very large videos
  (several GB) may fail on phones.
- Free third-party hosts (Litterbox, Catbox) can be slow or down. If posting to
  Instagram fails with "media could not be fetched", try again or switch to
  your own bucket.

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
- Backblaze B2 S3-compatible API: https://www.backblaze.com/docs/cloud-storage-s3-compatible-api
- Backblaze B2 pricing: https://www.backblaze.com/cloud-storage/pricing
- MinIO `mc anonymous set`: https://docs.min.io/community/minio-object-store/reference/minio-mc/mc-anonymous-set.html
- Nextcloud OCS Share API: https://docs.nextcloud.com/server/latest/developer_manual/client_apis/OCS/ocs-share-api.html
- Nextcloud sharing (user manual): https://docs.nextcloud.com/server/latest/user_manual/en/files/sharing.html
- Catbox API: https://catbox.moe/tools.php
- Catbox FAQ: https://catbox.moe/faq.php
- Litterbox API: https://litterbox.catbox.moe/tools.php

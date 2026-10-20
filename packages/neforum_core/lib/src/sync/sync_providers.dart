import 'package:meta/meta.dart';

/// How NEFORUM reaches the sync file.
enum SyncBackendKind {
  /// A folder a desktop cloud app keeps in sync (computers only).
  folder,

  /// A WebDAV folder, reached directly (computers and phones).
  webdav,

  /// An S3-compatible bucket, reached directly (computers and phones).
  s3,
}

/// One storage service in the sync settings: which kind it is and what to
/// fill in. Only hints: every WebDAV server and every S3-compatible store
/// works, listed or not.
@immutable
class SyncProvider {
  const SyncProvider({
    required this.id,
    required this.name,
    required this.kind,
    required this.hint,
    this.urlTemplate,
    this.region,
  });

  final String id;
  final String name;
  final SyncBackendKind kind;

  /// Where to find the folder, the address or the keys.
  final String hint;

  /// WebDAV folder URL or S3 endpoint, with `<placeholders>`.
  final String? urlTemplate;

  /// S3 region to suggest, when the provider needs a fixed one.
  final String? region;
}

/// Every provider the sync settings offer, folder apps first.
const List<SyncProvider> syncProviders = [
  // Desktop cloud apps: pick a folder they sync.
  SyncProvider(
      id: 'onedrive', name: 'OneDrive', kind: SyncBackendKind.folder, hint: 'Pick a folder inside your OneDrive folder, for example OneDrive\\NEFORUM. Right-click it and choose "Always keep on this device".'),
  SyncProvider(
      id: 'googledrive',
      name: 'Google Drive',
      kind: SyncBackendKind.folder,
      hint: 'Install Google Drive for desktop, then pick a folder in "My Drive" (the G: drive on Windows). Set it to "Available offline".'),
  SyncProvider(id: 'dropbox', name: 'Dropbox', kind: SyncBackendKind.folder, hint: 'Pick a folder inside your Dropbox folder. Make it "Available offline".'),
  SyncProvider(
      id: 'icloud',
      name: 'iCloud Drive',
      kind: SyncBackendKind.folder,
      hint: 'On a Mac, pick a folder in iCloud Drive and turn off "Optimise Mac Storage" for it. On Windows, use iCloud for Windows and pick a folder in iCloud Drive.'),
  SyncProvider(id: 'box', name: 'Box', kind: SyncBackendKind.folder, hint: 'Install Box Drive and pick a folder in it; mark it "Make available offline".'),
  SyncProvider(id: 'mega', name: 'MEGA', kind: SyncBackendKind.folder, hint: 'In the MEGA desktop app, sync a local folder, then pick that folder.'),
  SyncProvider(id: 'pcloud-drive', name: 'pCloud Drive', kind: SyncBackendKind.folder, hint: 'Pick a folder in pCloud Drive that is set to sync offline (or a pCloud Sync folder).'),
  SyncProvider(id: 'proton', name: 'Proton Drive', kind: SyncBackendKind.folder, hint: 'Install the Proton Drive app and pick a folder it syncs; keep it available offline.'),
  SyncProvider(id: 'syncdotcom', name: 'Sync.com', kind: SyncBackendKind.folder, hint: 'Pick a folder inside your Sync folder.'),
  SyncProvider(
      id: 'syncthing', name: 'Syncthing', kind: SyncBackendKind.folder, hint: 'Pick a folder Syncthing shares between your devices. No cloud at all: your devices sync with each other directly.'),
  SyncProvider(
      id: 'nextcloud-client', name: 'Nextcloud or ownCloud app', kind: SyncBackendKind.folder, hint: 'Pick a folder the Nextcloud (or ownCloud) desktop client syncs. Phones use WebDAV instead.'),
  SyncProvider(id: 'folder', name: 'Any other synced folder', kind: SyncBackendKind.folder, hint: 'Any folder another program keeps in sync, or a network share every computer can reach.'),

  // WebDAV: works on phones too.
  SyncProvider(
    id: 'nextcloud',
    name: 'Nextcloud',
    kind: SyncBackendKind.webdav,
    urlTemplate: 'https://<server>/remote.php/dav/files/<user>/NEFORUM',
    hint: 'Files > Settings (bottom left) shows the WebDAV address. Create an app password under Settings > Security.',
  ),
  SyncProvider(
    id: 'owncloud',
    name: 'ownCloud',
    kind: SyncBackendKind.webdav,
    urlTemplate: 'https://<server>/remote.php/dav/files/<user>/NEFORUM',
    hint: 'Settings > Security creates an app password. ownCloud Infinite Scale shows its WebDAV address under the file details.',
  ),
  SyncProvider(
    id: 'koofr',
    name: 'Koofr',
    kind: SyncBackendKind.webdav,
    urlTemplate: 'https://app.koofr.net/dav/Koofr/NEFORUM',
    hint: 'Your Koofr e-mail as the username and an app password from Preferences > Password > App passwords.',
  ),
  SyncProvider(
    id: 'pcloud',
    name: 'pCloud (WebDAV)',
    kind: SyncBackendKind.webdav,
    urlTemplate: 'https://webdav.pcloud.com/NEFORUM',
    hint: 'Use https://ewebdav.pcloud.com/NEFORUM if your account is in the EU region. Your pCloud e-mail and password.',
  ),
  SyncProvider(
    id: 'kdrive',
    name: 'Infomaniak kDrive',
    kind: SyncBackendKind.webdav,
    urlTemplate: 'https://<kDrive ID>.connect.kdrive.infomaniak.com/NEFORUM',
    hint: 'The kDrive ID is the number in your kDrive web address. Create an application password in your Infomaniak account.',
  ),
  SyncProvider(
    id: 'fastmail',
    name: 'Fastmail Files',
    kind: SyncBackendKind.webdav,
    urlTemplate: 'https://myfiles.fastmail.com/NEFORUM',
    hint: 'Your Fastmail address and an app password with "Files (WebDAV)" access (Settings > Privacy & Security).',
  ),
  SyncProvider(
    id: 'hetzner-box',
    name: 'Hetzner Storage Box',
    kind: SyncBackendKind.webdav,
    urlTemplate: 'https://<user>.your-storagebox.de/NEFORUM',
    hint: 'Turn on WebDAV for the Storage Box in the Hetzner console; the username looks like u123456.',
  ),
  SyncProvider(
    id: 'synology',
    name: 'Synology NAS',
    kind: SyncBackendKind.webdav,
    urlTemplate: 'https://<nas address>:5006/<shared folder>/NEFORUM',
    hint: 'Install "WebDAV Server" in Package Center and turn on HTTPS (port 5006). Reach it from outside home through QuickConnect or a VPN.',
  ),
  SyncProvider(
    id: 'qnap',
    name: 'QNAP NAS',
    kind: SyncBackendKind.webdav,
    urlTemplate: 'https://<nas address>/<shared folder>/NEFORUM',
    hint: 'Control Panel > Network & File Services > WebDAV: turn it on and give your user WebDAV access to the shared folder.',
  ),
  SyncProvider(
      id: 'webdav', name: 'Any WebDAV server', kind: SyncBackendKind.webdav, urlTemplate: 'https://<server>/<path>/NEFORUM', hint: 'The WebDAV address of a folder, with a username and password.'),

  // S3-compatible object storage: works on phones too.
  SyncProvider(
      id: 'aws',
      name: 'Amazon S3',
      kind: SyncBackendKind.s3,
      urlTemplate: 'https://s3.<region>.amazonaws.com',
      hint: 'An IAM key allowed to read and write one bucket (s3:GetObject, s3:PutObject, s3:DeleteObject).'),
  SyncProvider(
      id: 'r2',
      name: 'Cloudflare R2',
      kind: SyncBackendKind.s3,
      urlTemplate: 'https://<account id>.r2.cloudflarestorage.com',
      region: 'auto',
      hint: 'R2 > Manage API tokens: an "Object Read & Write" token for one bucket. Free up to 10 GB.'),
  SyncProvider(
      id: 'b2',
      name: 'Backblaze B2',
      kind: SyncBackendKind.s3,
      urlTemplate: 'https://s3.<region>.backblazeb2.com',
      hint: 'App Keys > Add a New Application Key for one bucket. The keyID is the access key, the applicationKey the secret.'),
  SyncProvider(id: 'wasabi', name: 'Wasabi', kind: SyncBackendKind.s3, urlTemplate: 'https://s3.<region>.wasabisys.com', hint: 'Access Keys > Create new access key; use the region of your bucket.'),
  SyncProvider(id: 'idrive-e2', name: 'IDrive e2', kind: SyncBackendKind.s3, urlTemplate: 'https://<endpoint shown in IDrive e2>', hint: 'Access Keys > Create access key, and copy the endpoint of your region.'),
  SyncProvider(id: 'scaleway', name: 'Scaleway', kind: SyncBackendKind.s3, urlTemplate: 'https://s3.<region>.scw.cloud', hint: 'Regions: fr-par, nl-ams or pl-waw. Create an API key with Object Storage access.'),
  SyncProvider(
      id: 'do-spaces', name: 'DigitalOcean Spaces', kind: SyncBackendKind.s3, urlTemplate: 'https://<region>.digitaloceanspaces.com', hint: 'API > Spaces Keys; the region is part of the endpoint (nyc3, ams3, sgp1...).'),
  SyncProvider(
      id: 'hetzner-s3',
      name: 'Hetzner Object Storage',
      kind: SyncBackendKind.s3,
      urlTemplate: 'https://<location>.your-objectstorage.com',
      hint: 'Locations: fsn1, nbg1 or hel1 (also the region). Create S3 credentials in the Hetzner console.'),
  SyncProvider(id: 'storj', name: 'Storj', kind: SyncBackendKind.s3, urlTemplate: 'https://gateway.storjshare.io', hint: 'Create S3 credentials ("Access Keys") in the Storj console.'),
  SyncProvider(id: 'minio', name: 'MinIO', kind: SyncBackendKind.s3, urlTemplate: 'https://<your server>', hint: 'Your MinIO server address and an access key for one bucket.'),
  SyncProvider(id: 's3', name: 'Any S3-compatible storage', kind: SyncBackendKind.s3, urlTemplate: 'https://<endpoint>', hint: 'The S3 API endpoint, a bucket, and an access key with its secret.'),
];

/// The provider with [id], or `null`.
SyncProvider? syncProviderById(String? id) {
  for (final p in syncProviders) {
    if (p.id == id) return p;
  }
  return null;
}

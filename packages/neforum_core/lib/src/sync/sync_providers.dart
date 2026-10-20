import 'package:meta/meta.dart';

/// How NEFORUM reaches the sync file.
enum SyncBackendKind {
  /// A cloud app's location: on a computer a folder the desktop app syncs;
  /// on a phone or tablet a folder, or the sync file itself, picked in the
  /// system file picker (the Files app on iOS).
  folder,

  /// NEFORUM talks to Google Drive's API directly with the user's own Google
  /// Cloud OAuth client; works on every platform.
  googleDrive,

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
    this.iosHint,
    this.androidHint,
    this.urlTemplate,
    this.region,
  });

  final String id;
  final String name;
  final SyncBackendKind kind;

  /// Where to find the folder, the address or the keys (on a computer).
  final String hint;

  /// For a folder provider, how to reach it on an iPhone or iPad (Files
  /// app); `null` when it has no iPhone app with a Files location.
  final String? iosHint;

  /// For a folder provider, how to reach it on Android (the system file
  /// picker); `null` when it has no Android app there.
  final String? androidHint;

  /// WebDAV folder URL or S3 endpoint, with `<placeholders>`.
  final String? urlTemplate;

  /// S3 region to suggest, when the provider needs a fixed one.
  final String? region;

  /// The hint for this device.
  String hintFor({bool ios = false, bool android = false}) => (ios ? iosHint : (android ? androidHint : null)) ?? hint;

  /// Whether this provider is offered on the device: a folder provider only
  /// where it has a hint; the others, reached directly, everywhere.
  bool availableOn({bool ios = false, bool android = false}) => switch (kind) {
        SyncBackendKind.folder => ios ? iosHint != null : (android ? androidHint != null : true),
        SyncBackendKind.googleDrive || SyncBackendKind.webdav || SyncBackendKind.s3 => true,
      };
}

/// iPhone hint for a cloud app whose folders iOS lets NEFORUM pick.
String _iosFolder(String app, String location) =>
    'Install the $app app and sign in, then Choose folder and pick a folder under $location. '
    'If it is missing from the picker, open the Files app, tap Browse, then ⋯ > Edit, and turn it on. '
    'If it is grayed out, use Choose the sync file or Create the sync file instead.';

/// iPhone hint for a cloud app that does not let other apps pick its
/// folders (grayed out in the folder picker) but does let them open and save
/// one file in place.
String _iosFile(String app, String location) =>
    '$app does not let other apps pick its folders (it is grayed out in the folder picker), so pick the file: install the '
    '$app app and sign in, then Choose the sync file and select NEFORUM.neforumsync under $location (your computer makes it '
    'there), or Create the sync file to make it under $location from this device. If $location is missing, open the Files '
    'app, tap Browse, then ⋯ > Edit, and turn it on.';

/// Android hint for a cloud app: Android's picker opens and saves single
/// files in most cloud apps, but few let apps pick their folders.
String _androidFile(String app) =>
    'Install the $app app and sign in. Then Choose the sync file and select NEFORUM.neforumsync in $app (your computer makes '
    'it there), or Create the sync file to make it in $app from this phone. If $app is missing from the picker or saving '
    'fails, use WebDAV or S3.';

/// Every provider the sync settings offer, folder apps first.
final List<SyncProvider> syncProviders = List.unmodifiable([
  // Cloud apps: on a computer a folder they sync, on a phone or tablet a
  // location in the system file picker.
  SyncProvider(
    id: 'onedrive',
    name: 'OneDrive',
    kind: SyncBackendKind.folder,
    hint: 'Pick a folder inside your OneDrive folder, for example OneDrive\\NEFORUM. Right-click it and choose "Always keep on this device".',
    iosHint: _iosFile('OneDrive', 'OneDrive'),
    androidHint: _androidFile('OneDrive'),
  ),
  SyncProvider(
    id: 'googledrive',
    name: 'Google Drive',
    kind: SyncBackendKind.folder,
    // Not offered on phones: Google Drive's apps there cannot have their
    // folders picked and often do not hand the file over.
    hint: 'Install Google Drive for desktop, then pick a folder in "My Drive" (the G: drive on Windows). Set it to "Available offline". '
        'Phones and tablets cannot use this folder: if one should sync too, choose Google Drive (direct) on every device instead.',
  ),
  SyncProvider(
    id: 'dropbox',
    name: 'Dropbox',
    kind: SyncBackendKind.folder,
    hint: 'Pick a folder inside your Dropbox folder. Make it "Available offline".',
    iosHint: _iosFolder('Dropbox', 'Dropbox'),
    androidHint: _androidFile('Dropbox'),
  ),
  SyncProvider(
    id: 'icloud',
    name: 'iCloud Drive',
    kind: SyncBackendKind.folder,
    hint: 'On a Mac, pick a folder in iCloud Drive and turn off "Optimise Mac Storage" for it. On Windows, use iCloud for Windows and pick a folder in iCloud Drive.',
    iosHint: 'Choose folder and pick a folder in iCloud Drive. iCloud Drive must be on: Settings > your name > iCloud > iCloud Drive.',
  ),
  SyncProvider(
    id: 'box',
    name: 'Box',
    kind: SyncBackendKind.folder,
    hint: 'Install Box Drive and pick a folder in it; mark it "Make available offline".',
    iosHint: _iosFolder('Box', 'Box'),
    androidHint: _androidFile('Box'),
  ),
  SyncProvider(
    id: 'mega',
    name: 'MEGA',
    kind: SyncBackendKind.folder,
    hint: 'In the MEGA desktop app, sync a local folder, then pick that folder.',
    iosHint: _iosFile('MEGA', 'MEGA'),
    androidHint: _androidFile('MEGA'),
  ),
  SyncProvider(
    id: 'pcloud-drive',
    name: 'pCloud Drive',
    kind: SyncBackendKind.folder,
    hint: 'Pick a folder in pCloud Drive that is set to sync offline (or a pCloud Sync folder).',
    iosHint: _iosFolder('pCloud', 'pCloud'),
    androidHint: _androidFile('pCloud'),
  ),
  SyncProvider(
    id: 'proton',
    name: 'Proton Drive',
    kind: SyncBackendKind.folder,
    hint: 'Install the Proton Drive app and pick a folder it syncs; keep it available offline.',
    iosHint: _iosFolder('Proton Drive', 'Proton Drive'),
    androidHint: _androidFile('Proton Drive'),
  ),
  SyncProvider(
    id: 'syncdotcom',
    name: 'Sync.com',
    kind: SyncBackendKind.folder,
    hint: 'Pick a folder inside your Sync folder.',
    iosHint: _iosFolder('Sync.com', 'Sync'),
    androidHint: _androidFile('Sync.com'),
  ),
  SyncProvider(
    id: 'syncthing',
    name: 'Syncthing',
    kind: SyncBackendKind.folder,
    hint: 'Pick a folder Syncthing shares between your devices. No cloud at all: your devices sync with each other directly.',
    iosHint: 'Install Möbius Sync (Syncthing for iPhone), share a folder with your computers, then Choose folder and pick it under On My iPhone > Möbius Sync.',
    androidHint: 'Install Syncthing-Fork, share a folder with your computers, then Choose folder and pick that folder on this phone.',
  ),
  SyncProvider(
    id: 'nextcloud-client',
    name: 'Nextcloud or ownCloud app',
    kind: SyncBackendKind.folder,
    hint: 'Pick a folder the Nextcloud (or ownCloud) desktop client syncs.',
    iosHint: _iosFolder('Nextcloud (or ownCloud)', 'Nextcloud'),
    androidHint: 'Install the Nextcloud (or ownCloud) app and sign in, then Choose folder and pick a folder under it, or Choose the sync file. '
        'You can also use the WebDAV option with the same server.',
  ),
  SyncProvider(
    id: 'folder',
    name: 'Any other synced folder',
    kind: SyncBackendKind.folder,
    hint: 'Any folder another program keeps in sync, or a network share every computer can reach.',
    iosHint: 'Any location the Files app shows that your other devices also reach: Choose folder, or Choose the sync file where folders are grayed out.',
    androidHint: 'A folder on this phone that another app keeps in sync (Syncthing-Fork, FolderSync, Autosync), or the sync file in any app the picker shows.',
  ),
  // Google Drive through its API: works on phones too.
  SyncProvider(
    id: 'googledrive-direct',
    name: 'Google Drive (direct)',
    kind: SyncBackendKind.googleDrive,
    hint: "NEFORUM reaches Google Drive itself through your own Google Cloud project (the one for NEFORUM's YouTube connection works "
        'too). In the Google Cloud console: enable the Google Drive API; set up the OAuth consent screen (External) with the drive.file '
        'scope; under Audience > Test users, add your own Google address (every account you will sign in with); optionally click '
        'Publish app so sign-ins do not expire after 7 days; then create an OAuth client of type "Desktop app" and paste its '
        'Client ID and Client secret here. The file goes in a "NEFORUM Sync" folder in My Drive. Choose this option on every device: '
        'it cannot see a file Google Drive for desktop put in a folder.',
  ),
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
]);

/// The provider with [id], or `null`.
SyncProvider? syncProviderById(String? id) {
  for (final p in syncProviders) {
    if (p.id == id) return p;
  }
  return null;
}

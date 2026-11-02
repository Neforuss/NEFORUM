import 'package:meta/meta.dart';

import '../auth/oauth2_pkce.dart';

/// 1.3.5: whose setup a device's first sync keeps where this device and the
/// sync file hold different versions of the same record. Everything only one
/// side has is kept either way: a first sync never deletes anything.
enum SyncSeed {
  /// This device's version is kept and goes into the file.
  thisDevice,

  /// The file's version (the devices already syncing) is kept here.
  file,
}

/// One side of a first sync as the seed rule sees it: how many accounts it
/// has and when its oldest one was connected.
@immutable
class SyncSideSummary {
  const SyncSideSummary({required this.accounts, this.oldestConnection});

  /// The summary of accounts as they travel (ConnectedAccount JSON); entries
  /// that are not accounts are skipped.
  factory SyncSideSummary.ofAccounts(Iterable<Object?> accounts) {
    var count = 0;
    DateTime? oldest;
    for (final a in accounts) {
      if (a is! Map) continue;
      count++;
      final at = DateTime.tryParse('${a['createdAt'] ?? ''}');
      if (at != null && (oldest == null || at.isBefore(oldest))) oldest = at;
    }
    return SyncSideSummary(accounts: count, oldestConnection: oldest);
  }

  final int accounts;

  /// When the oldest account on this side was connected, or `null` when it
  /// has none (or none with a readable date).
  final DateTime? oldestConnection;

  @override
  bool operator ==(Object other) => other is SyncSideSummary && other.accounts == accounts && other.oldestConnection == oldestConnection;

  @override
  int get hashCode => Object.hash(accounts, oldestConnection);

  @override
  String toString() => 'SyncSideSummary($accounts accounts, oldest ${oldestConnection?.toIso8601String()})';
}

/// 1.3.5: the seed rule. The side with more accounts gives its setup; on a
/// tie, the side whose oldest account connection is older (it has been in use
/// longest); on a full tie the file, because other devices already agree on
/// it and a joining device changes none of them.
SyncSeed chooseSyncSeed({required SyncSideSummary here, required SyncSideSummary file}) {
  if (here.accounts != file.accounts) return here.accounts > file.accounts ? SyncSeed.thisDevice : SyncSeed.file;
  final h = here.oldestConnection, f = file.oldestConnection;
  if (h != null && (f == null || h.isBefore(f))) return SyncSeed.thisDevice;
  return SyncSeed.file;
}

/// The whole made-up forms: a bare UUID, or a network prefix with
/// `:handoff:`, `-handoff-` or `-handoff:` before it. A UUID inside a natural
/// id (`deviantart:<the user's UUID>`) does not count.
final RegExp _madeUp = RegExp(r'^(?:[a-z0-9_]+(?::handoff:|-handoff-|-handoff:))?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final RegExp _clockId = RegExp(r'^nostr-handoff-\d+$');

/// 1.3.5: whether [id] was made up on the device that connected the account
/// rather than taken from the account itself. Only accounts with a made-up
/// id can be the same account under two ids: two different natural ids are
/// two different accounts.
///
/// From every adapter's connect(), as of 1.3.5:
/// * made up: Mastodon and Pixelfed (a UUID on both tiers), TikTok (a UUID),
///   YouTube hand-off (a UUID), the hand-off accounts of DeviantArt,
///   Dribbble, Facebook, Flickr, Inkbunny, Instagram, LinkedIn, Odysee,
///   Pinterest, Reddit, Tumblr, X, YouTube posts, Threads without a username
///   and every hand-off-only network (`<network>:handoff:<UUID>`), and Nostr
///   hand-off (`nostr-handoff-<microseconds>`);
/// * natural: everything else, built from the account's own id on its
///   network (`x-<user id>`, `bluesky:<did>`, `misskey:<user id>@<server>`,
///   `lemmy:<name>@<server>`, `youtube:<channel id>`, `discord:<webhook id>`,
///   ...) or from its server (`lemmy-handoff:<server>`), the same on every
///   device for the same account.
bool isDeviceMadeAccountId(String id) => _madeUp.hasMatch(id) || _clockId.hasMatch(id);

/// 1.3.5: an account handle as compared across devices: case-insensitive,
/// without the leading `@`, `null` when empty. `@Alice@Mastodon.Social` and
/// `alice@mastodon.social` are the same handle.
String? normalizedAccountHandle(Object? handle) {
  if (handle is! String) return null;
  final h = handle.trim().replaceFirst(RegExp('^@+'), '').toLowerCase();
  return h.isEmpty ? null : h;
}

String? _text(Object? v) {
  if (v is! String && v is! num) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

/// 1.3.5: the server an account lives on, when its adapter recorded one:
/// `domain` (Mastodon, Pixelfed), or the host of `instance` (Mastodon,
/// Lemmy, Misskey, WriteFreely), `site` (WordPress, Ghost), `base` (Dev.to)
/// or `baseUrl`, or `host`. `null` when none can be read: a missing server
/// never matches a present one, and never matches another missing one.
String? accountServer(Map<Object?, Object?> account) {
  final config = account['config'];
  if (config is! Map) return null;
  final domain = _text(config['domain']);
  if (domain != null) return domain.toLowerCase();
  for (final key in const ['instance', 'site', 'base', 'baseUrl']) {
    final host = Uri.tryParse(_text(config[key]) ?? '')?.host ?? '';
    if (host.isNotEmpty) return host.toLowerCase();
  }
  return _text(config['host'])?.toLowerCase();
}

/// 1.3.5: the account's own identity on its network, for accounts whose id
/// was made up on the device, when the adapter recorded it:
/// * TikTok: `openId`, TikTok's id of the user for one developer app, with
///   that app's `clientKey`;
/// * Mastodon and Pixelfed: `remoteAccountId`, the account's id on its
///   server, with the server ([accountServer]).
/// `null` when a part is missing.
String? naturalAccountKey(Map<Object?, Object?> account) {
  final config = account['config'];
  if (config is! Map) return null;
  final openId = _text(config['openId']);
  if (openId != null) {
    final app = _text(config['clientKey']);
    return app == null ? null : 'openId:$openId@$app';
  }
  final remote = _text(config['remoteAccountId']);
  if (remote != null) {
    final server = accountServer(account);
    return server == null ? null : 'remote:$remote@$server';
  }
  return null;
}

/// 1.3.5: the site a hand-off account posts to, whole: host and path
/// (`example.com/blog-one`), from `site`, `instance`, `base` or `baseUrl`,
/// else its `domain`; `null` when it records none. Two blogs of one
/// WordPress multisite share a host, never a path.
String? handoffSite(Map<Object?, Object?> account) {
  final config = account['config'];
  if (config is! Map) return null;
  for (final key in const ['site', 'instance', 'base', 'baseUrl']) {
    final u = Uri.tryParse(_text(config[key]) ?? '');
    if (u != null && u.host.isNotEmpty) return '${u.host.toLowerCase()}${u.path.replaceFirst(RegExp(r'/+$'), '')}';
  }
  return _text(config['domain'])?.toLowerCase();
}

/// 1.3.5: whether the accounts [a] and [b] (ConnectedAccount JSON, different
/// ids) are one account connected on two devices. Same network, same tier
/// family (hand-off or not), at least one id made up on its device
/// ([isDeviceMadeAccountId]: two ids taken from the accounts themselves are
/// two accounts, whatever the tier), not on two different servers when both
/// record one ([accountServer]), and:
///
/// * hand-off accounts: not two different sites ([handoffSite], path
///   included) or handles when both record one, and the same name or the
///   same handle;
/// * other accounts: the same identity on the network ([naturalAccountKey])
///   when both recorded it, otherwise the same handle
///   ([normalizedAccountHandle]).
///
/// Different accounts on one network are never the same: their natural ids,
/// identities, servers, sites or handles differ. When two copies that are
/// the same may actually merge is the sync engine's call (a hand-off only on
/// a device's first sync, for one).
bool isSameConnectedAccount(Map<Object?, Object?> a, Map<Object?, Object?> b) {
  final platform = a['platformId'];
  if (platform is! String || platform != b['platformId']) return false;
  final handoffA = a['tier'] == 'handoff', handoffB = b['tier'] == 'handoff';
  if (handoffA != handoffB) return false;
  if (!isDeviceMadeAccountId('${a['id']}') && !isDeviceMadeAccountId('${b['id']}')) return false;
  final sa = accountServer(a), sb = accountServer(b);
  if (sa != null && sb != null && sa != sb) return false;
  final ha = normalizedAccountHandle(a['handle']), hb = normalizedAccountHandle(b['handle']);
  if (handoffA) {
    final pa = handoffSite(a), pb = handoffSite(b);
    if (pa != null && pb != null && pa != pb) return false;
    if (ha != null && hb != null && ha != hb) return false;
    return (a['displayName'] is String && a['displayName'] == b['displayName']) || (ha != null && ha == hb);
  }
  final na = naturalAccountKey(a), nb = naturalAccountKey(b);
  if (na != null && nb != null) return na == nb;
  return ha != null && ha == hb;
}

/// 1.3.5: of two copies of one account, whether [first] holds the newer
/// sign-in: the keys that expire later (renewed more recently) when both
/// expire, otherwise the account connected later. A tie is not newer.
bool holdsNewerSignIn({required Map<Object?, Object?> first, Map<Object?, Object?>? firstKeys, required Map<Object?, Object?> second, Map<Object?, Object?>? secondKeys}) {
  DateTime? at(Object? v) => DateTime.tryParse('${v ?? ''}');
  final e1 = at(firstKeys?[OAuthTokens.keyExpiresAt]), e2 = at(secondKeys?[OAuthTokens.keyExpiresAt]);
  if (e1 != null && e2 != null && e1 != e2) return e1.isAfter(e2);
  final c1 = at(first['createdAt']), c2 = at(second['createdAt']);
  return c1 != null && c2 != null && c1.isAfter(c2);
}

/// 1.3.5: what a sync would do, worked out without doing it
/// ([SyncEngine.preview]): the "dry run" a device shows before its first
/// sync. It comes from the same planning code as the sync itself, so what it
/// says is what the sync then does (unless the file or this device changes
/// in between).
@immutable
class SyncPreview {
  const SyncPreview({
    required this.fileExists,
    required this.firstJoin,
    required this.here,
    required this.file,
    required this.received,
    required this.sent,
    required this.mergedAccounts,
    required this.fromDevices,
    this.removed = const {},
    this.mergedInFile = const {},
    this.mergeEdits = const {},
    this.hereBefore = const {},
    this.sentValues = const {},
    this.fileBefore = const {},
    this.seed,
  });

  /// Whether there is a sync file yet (if not, this device creates it).
  final bool fileExists;

  /// Whether this is the device's first sync with the file.
  final bool firstJoin;

  /// Whose version is kept where both sides differ, on a first sync.
  final SyncSeed? seed;

  /// This device's and the file's accounts, as the seed rule saw them.
  final SyncSideSummary here;
  final SyncSideSummary file;

  /// Records this device takes from the file: key (`account:<id>`,
  /// `setting:<key>`, `mediaHosts:all`...) -> the value it stores (a setting
  /// may be `null`: its default). Holds keys: never log or show the values.
  final Map<String, Object?> received;

  /// Records the file deleted that this device removes too. Never on a
  /// first sync.
  final Set<String> removed;

  /// What this device held for each [received] record before (`null`:
  /// nothing), so a dry run can say what really changes here.
  final Map<String, Object?> hereBefore;

  /// Records this device writes into the file.
  final Set<String> sent;

  /// The value written for each [sent] record (`null`: a deletion).
  final Map<String, Object?> sentValues;

  /// What the file held for each [sent] record before (`null`: nothing).
  final Map<String, Object?> fileBefore;

  /// Accounts connected on both sides under two ids, merged into one: this
  /// device's id -> the id the file has (and keeps).
  final Map<String, String> mergedAccounts;

  /// Of [mergedAccounts], the ones this device held in neither copy: the
  /// sync file held one account twice. Their merged account counts as
  /// [received].
  final Set<String> mergedInFile;

  /// What merging those accounts stores here before anything else: the
  /// account under the file's id, its keys, the posts and settings that
  /// named the old id, and the old copy's removal (`null`). Holds keys too.
  final Map<String, Object?> mergeEdits;

  /// The names of the devices whose records arrive, most records first.
  final List<String> fromDevices;

  /// How many records of [prefix] arrive or change here.
  int receivedOf(String prefix) => received.keys.where((k) => k.startsWith('$prefix:')).length;

  /// How many sent records are of [prefix].
  int sentOf(String prefix) => sent.where((k) => k.startsWith('$prefix:')).length;
}

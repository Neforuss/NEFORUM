// U8a: one row per adapter in builtinAdapters(), and the same facts in
// docs/sign-in-lifetimes.md. A 49th adapter fails here twice: once for having
// no row, and once at compile time for having no signInPolicyFor.

import 'dart:io';

import 'package:neforum_core/neforum_core.dart';
import 'package:test/test.dart';

/// What each adapter declares for its main way of connecting, written out by
/// hand so a change to a policy has to change this table too.
class _Row {
  const _Row(this.id, this.name, this.limit, this.renewal, {this.early = true, this.unverified = false, this.disuse, this.config = const {}, this.tier = PlatformTier.openApi});
  const _Row.handoff(this.id, this.name)
      : limit = null,
        renewal = null,
        early = false,
        unverified = false,
        disuse = null,
        config = const {},
        tier = PlatformTier.handoff;

  final String id;
  final String name;
  final SignInLimit? limit;
  final SignInRenewal? renewal;
  final bool early;
  final bool unverified;
  final int? disuse;
  final Map<String, dynamic> config;
  final PlatformTier tier;

  ConnectedAccount get account => ConnectedAccount(id: 'row-$id', platformId: id, tier: tier, displayName: name, createdAt: DateTime.utc(2026, 11, 6), config: config);
}

const _byok = PlatformTier.byokApi;

const List<_Row> _table = [
  _Row.handoff('fivehundredpx', '500px'),
  _Row.handoff('artfol', 'Artfol'),
  _Row.handoff('artstation', 'ArtStation'),
  _Row.handoff('behance', 'Behance'),
  _Row.handoff('bitchute', 'BitChute'),
  _Row('bluesky', 'Bluesky', SignInLimit.date, SignInRenewal.credential),
  _Row.handoff('cara', 'Cara'),
  _Row('devto', 'DEV Community', SignInLimit.none, SignInRenewal.notNeeded),
  _Row('deviantart', 'DeviantArt', SignInLimit.date, SignInRenewal.onUse, disuse: 90, unverified: true, tier: _byok),
  _Row('discord', 'Discord', SignInLimit.undocumented, SignInRenewal.notNeeded, unverified: true),
  _Row('dribbble', 'Dribbble', SignInLimit.undocumented, SignInRenewal.notNeeded, unverified: true, tier: _byok),
  _Row('facebook', 'Facebook', SignInLimit.none, SignInRenewal.notNeeded, tier: _byok),
  _Row('flickr', 'Flickr', SignInLimit.undocumented, SignInRenewal.notNeeded, unverified: true, tier: _byok),
  _Row.handoff('furaffinity', 'Fur Affinity'),
  _Row('ghost', 'Ghost', SignInLimit.undocumented, SignInRenewal.notNeeded, unverified: true),
  _Row.handoff('google_business', 'Google Business Profile'),
  _Row('hashnode', 'Hashnode', SignInLimit.undocumented, SignInRenewal.notNeeded, unverified: true, tier: _byok),
  _Row('inkbunny', 'Inkbunny', SignInLimit.idleUnknown, SignInRenewal.never),
  _Row('instagram', 'Instagram', SignInLimit.date, SignInRenewal.onUse, disuse: 60, tier: _byok),
  _Row.handoff('itaku', 'Itaku'),
  _Row.handoff('kofi', 'Ko-fi'),
  _Row('lemmy', 'Lemmy', SignInLimit.none, SignInRenewal.notNeeded),
  _Row('linkedin', 'LinkedIn', SignInLimit.date, SignInRenewal.never, tier: _byok),
  _Row('mastodon', 'Mastodon', SignInLimit.none, SignInRenewal.notNeeded, config: {'software': 'mastodon'}),
  _Row('matrix', 'Matrix', SignInLimit.undocumented, SignInRenewal.onUse, config: {'authMethod': 'password'}),
  _Row('micropub', 'Micropub (IndieWeb / Micro.blog)', SignInLimit.undocumented, SignInRenewal.onUse, config: {'authMethod': 'indieauth'}),
  _Row('misskey', 'Misskey', SignInLimit.none, SignInRenewal.notNeeded),
  _Row.handoff('newgrounds', 'Newgrounds'),
  _Row('nostr', 'Nostr', SignInLimit.none, SignInRenewal.notNeeded, early: false),
  _Row.handoff('odysee', 'Odysee'),
  _Row('pinterest', 'Pinterest', SignInLimit.date, SignInRenewal.onUse, disuse: 60, tier: _byok),
  _Row('pixelfed', 'Pixelfed', SignInLimit.date, SignInRenewal.onUse, disuse: 400, unverified: true),
  _Row.handoff('pixiv', 'pixiv'),
  _Row('reddit', 'Reddit', SignInLimit.undocumented, SignInRenewal.onUse, unverified: true, tier: _byok),
  _Row.handoff('rumble', 'Rumble'),
  _Row.handoff('snapchat', 'Snapchat'),
  _Row.handoff('substack', 'Substack Notes'),
  _Row('telegram', 'Telegram', SignInLimit.undocumented, SignInRenewal.notNeeded, unverified: true),
  _Row('threads', 'Threads', SignInLimit.date, SignInRenewal.onUse, disuse: 60, tier: _byok),
  _Row('tiktok', 'TikTok', SignInLimit.date, SignInRenewal.onUse, unverified: true, tier: _byok),
  _Row('tumblr', 'Tumblr', SignInLimit.date, SignInRenewal.onUse, disuse: 42, unverified: true, tier: _byok, config: {'authMode': 'oauth2'}),
  _Row.handoff('weasyl', 'Weasyl'),
  _Row.handoff('whatsapp', 'WhatsApp'),
  _Row('wordpress', 'WordPress', SignInLimit.none, SignInRenewal.notNeeded),
  _Row('writefreely', 'Write.as / WriteFreely', SignInLimit.none, SignInRenewal.notNeeded, config: {'instance': 'https://blog.example/'}),
  _Row('x', 'X (Twitter)', SignInLimit.date, SignInRenewal.onUse, disuse: 183, unverified: true, tier: _byok, config: {'authMode': 'oauth2'}),
  _Row('youtube', 'YouTube', SignInLimit.date, SignInRenewal.onUse, disuse: 183, tier: _byok),
  _Row.handoff('youtube_posts', 'YouTube Posts'),
];

/// The other ways of connecting, as `docs/sign-in-lifetimes.md` labels them.
const Map<String, _Row> _variants = {
  'X (Twitter): OAuth 1.0a keys': _Row('x', '', SignInLimit.date, SignInRenewal.never, tier: _byok, config: {'authMode': 'oauth1'}),
  'Tumblr: OAuth 1.0a keys': _Row('tumblr', '', SignInLimit.undocumented, SignInRenewal.notNeeded, unverified: true, tier: _byok, config: {'authMode': 'oauth1'}),
  'Mastodon: GoToSocial': _Row('mastodon', '', SignInLimit.none, SignInRenewal.notNeeded, config: {'software': 'gotosocial'}),
  'Mastodon: Pleroma': _Row('mastodon', '', SignInLimit.date, SignInRenewal.onUse, unverified: true, config: {'software': 'pleroma'}),
  'Mastodon: Akkoma': _Row('mastodon', '', SignInLimit.date, SignInRenewal.onUse, unverified: true, config: {'software': 'akkoma'}),
  'Mastodon: Mitra': _Row('mastodon', '', SignInLimit.date, SignInRenewal.never, unverified: true, config: {'software': 'mitra'}),
  'Mastodon: other servers': _Row('mastodon', '', SignInLimit.undocumented, SignInRenewal.notNeeded, unverified: true, config: {'software': 'friendica'}),
  'Matrix: token pasted from Element': _Row('matrix', '', SignInLimit.undocumented, SignInRenewal.never, unverified: true, config: {'authMethod': 'token'}),
  'Micropub: Micro.blog app token': _Row('micropub', '', SignInLimit.undocumented, SignInRenewal.notNeeded, unverified: true, config: {'authMethod': 'token', 'microblog': true}),
  'Write.as / WriteFreely: Write.as hosted': _Row('writefreely', '', SignInLimit.undocumented, SignInRenewal.notNeeded, unverified: true, config: {'instance': 'https://write.as/'}),
};

/// The rows of the table under [heading] in the doc, split into cells.
List<List<String>> _docRows(String doc, String heading) {
  final lines = doc.split(RegExp(r'\r?\n'));
  final start = lines.indexOf(heading);
  expect(start, greaterThanOrEqualTo(0), reason: 'the doc has "$heading"');
  final rows = <List<String>>[];
  for (final line in lines.skip(start + 1)) {
    if (line.startsWith('## ')) break;
    if (!line.startsWith('|')) continue;
    rows.add(line.substring(1, line.length - 1).split('|').map((c) => c.trim()).toList());
  }
  return rows.skip(2).toList(); // Past the header and its rule.
}

const _h = (name: 0, lifetime: 1, renews: 2, act: 3, early: 4, source: 5, date: 6, status: 7);

void _checkRow(List<String> cells, SignInPolicy p, String label) {
  expect(cells, hasLength(8), reason: label);
  expect(cells[_h.date], '2026-11-06', reason: '$label is dated');
  for (final i in [_h.lifetime, _h.renews, _h.act, _h.early, _h.source]) {
    expect(cells[i], isNotEmpty, reason: '$label has every column');
  }
  final renews = cells[_h.renews];
  if (!p.hasConnection) {
    expect(renews, 'Not applicable', reason: label);
    expect(cells[_h.source], contains("NEFORUM's code"), reason: label);
    return;
  }
  expect(cells[_h.source], contains(p.sourceUrl!), reason: '$label cites the page its policy cites');
  switch (p.renewal) {
    case SignInRenewal.onUse:
      expect(renews, startsWith('Yes, when NEFORUM posts'), reason: label);
    case SignInRenewal.credential:
      expect(renews, startsWith('Yes, with'), reason: label);
    case SignInRenewal.notNeeded:
      expect(renews, 'Not needed', reason: label);
    case SignInRenewal.never:
      expect(renews, 'No', reason: label);
  }
  expect(cells[_h.early], p.earlyRevocationPossible ? startsWith('Yes') : startsWith('None'), reason: label);
  final status = cells[_h.status];
  if (p.unverified) {
    expect(status, startsWith('UNVERIFIED'), reason: label);
    expect(status, contains('Settled'), reason: '$label says what would settle it');
  } else {
    expect(status, startsWith('VERIFIED'), reason: label);
  }
}

void main() {
  final adapters = {for (final a in builtinAdapters()) a.id: a};
  final doc = File('../../docs/sign-in-lifetimes.md').readAsStringSync();

  test('one row per adapter: a 49th adapter fails here', () {
    expect(_table.map((r) => r.id).toSet(), adapters.keys.toSet());
    expect(_table, hasLength(48));
    expect(adapters, hasLength(48));
  });

  for (final r in _table) {
    test('${r.id} declares what the table says', () {
      final a = adapters[r.id]!;
      expect(a.descriptor.name, r.name);
      final p = a.signInPolicyFor(r.account);
      if (r.limit == null) {
        expect(p.hasConnection, isFalse);
        return;
      }
      expect(p.hasConnection, isTrue);
      expect((p.limit, p.renewal, p.earlyRevocationPossible, p.unverified, p.disuseWindow?.inDays), (r.limit, r.renewal, r.early, r.unverified, r.disuse));
      expect(p.sourceUrl, startsWith('https://'), reason: 'every policy with a connection cites its page');
    });
  }

  for (final e in _variants.entries) {
    test('${e.key} declares what the table says', () {
      final p = adapters[e.value.id]!.signInPolicyFor(e.value.account);
      expect((p.limit, p.renewal, p.unverified), (e.value.limit, e.value.renewal, e.value.unverified));
    });
  }

  test('every API adapter on its hand-off tier has no connection', () {
    for (final a in adapters.values) {
      for (final spec in a.connectSpecs.where((s) => s.tier == PlatformTier.handoff)) {
        final account = ConnectedAccount(id: 'h', platformId: a.id, tier: spec.tier, displayName: 'h', createdAt: DateTime.utc(2026));
        expect(a.signInPolicyFor(account).hasConnection, isFalse, reason: a.id);
      }
    }
  });

  group('docs/sign-in-lifetimes.md', () {
    test('its 48 rows are the 48 adapters, each dated and matching the policy', () {
      final rows = _docRows(doc, '## All 48 networks');
      expect(rows, hasLength(48));
      expect(rows.map((c) => c[_h.name]).toSet(), adapters.values.map((a) => a.descriptor.name).toSet());
      for (final r in _table) {
        final cells = rows.firstWhere((c) => c[_h.name] == r.name);
        _checkRow(cells, adapters[r.id]!.signInPolicyFor(r.account), r.name);
      }
    });

    test('its second table covers every other way of connecting', () {
      final rows = _docRows(doc, '## Where one network has more than one way');
      expect(rows.map((c) => c[_h.name]).toSet(), _variants.keys.toSet());
      for (final e in _variants.entries) {
        _checkRow(rows.firstWhere((c) => c[_h.name] == e.key), adapters[e.value.id]!.signInPolicyFor(e.value.account), e.key);
      }
    });

    test('a VERIFIED row with an open clause says what would settle it, and Still open lists it', () {
      final open = RegExp('conflict|not stated|not known|unread|may differ|still says');
      final rows = [..._docRows(doc, '## All 48 networks'), ..._docRows(doc, '## Where one network has more than one way')];
      final clauses = rows.where((c) => c[_h.status].startsWith('VERIFIED') && open.hasMatch(c[_h.status])).toList();
      expect(clauses.map((c) => c[_h.name]), containsAll(['Pinterest', 'Threads', 'YouTube', 'Facebook', 'Misskey', 'Bluesky']), reason: 'the scan finds them');
      for (final c in clauses) {
        expect(c[_h.status], contains('Settled by'), reason: c[_h.name]);
      }
      final lines = doc.split(RegExp(r'\r?\n'));
      final still = lines.sublist(lines.indexOf('## Still open')).join('\n');
      for (final question in ["Pinterest's old renewal key", 'private profiles', 'Google app in Testing', "Misskey's forks"]) {
        expect(still, contains(question), reason: 'Still open lists it');
      }
    });

    test('says "no published limit", never "never expires", and uses plain words', () {
      expect(doc, isNot(contains('—')), reason: 'no em dashes');
      for (final line in doc.split('\n').where((l) => l.startsWith('|'))) {
        expect(line.toLowerCase(), isNot(contains('never expires')), reason: line);
      }
    });
  });

  group('every date for a platform with early revocation carries the flag', () {
    final now = DateTime.utc(2026, 11, 6);
    final ahead = now.add(const Duration(days: 20)).toIso8601String();
    final dated = <String, Map<String, String>>{
      'no refresh token': {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyExpiresAt: ahead},
      'refresh token with an end': {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyRefreshToken: 'r', StoredSecretKeys.refreshExpiresAt: ahead},
      'worked out from a window': {OAuthTokens.keyAccessToken: 'a', OAuthTokens.keyRefreshToken: 'r', StoredSecretKeys.lastRenewedAt: now.toIso8601String()},
    };
    for (final r in [..._table.where((r) => r.limit != null), ..._variants.values]) {
      test('${r.id} ${r.config}', () {
        final p = adapters[r.id]!.signInPolicyFor(r.account);
        dated.forEach((label, secrets) {
          final life = deriveSignInLifetime(p, secrets, now: now);
          if (life.expiresAt != null) expect(life.earlyRevocationPossible, r.id == 'nostr' ? isFalse : isTrue, reason: '$label on ${r.id}');
        });
      });
    }
  });

  test('a window on a refresh token comes with the access token\'s life: without it an old sign-in\'s date is late by that much', () {
    for (final r in [..._table.where((r) => r.limit != null), ..._variants.values]) {
      final p = adapters[r.id]!.signInPolicyFor(r.account);
      if (p.disuseWindow != null && !p.tokenRenewsItself) expect(p.accessLife, isNotNull, reason: r.id);
    }
    expect(SignInPolicies.pixelfedPolicy.accessLife, const Duration(days: 365));
    expect(SignInPolicies.pinterest.accessLife, const Duration(days: 30));
  });

  test('X keys carry the vendor\'s deadline; Tumblr and Flickr keys do not', () {
    final x = adapters['x']!.signInPolicyFor(_variants['X (Twitter): OAuth 1.0a keys']!.account);
    expect(x.hardDeadline, DateTime.utc(2027, 1, 31));
    expect(adapters['tumblr']!.signInPolicyFor(_variants['Tumblr: OAuth 1.0a keys']!.account).hardDeadline, isNull);
    expect(SignInPolicies.flickrPolicy.hardDeadline, isNull);
  });

  test('platforms that document rotation declare it, per account', () {
    ConnectedAccount a(String id, PlatformTier tier, [Map<String, dynamic> config = const {}]) => ConnectedAccount(id: 'r', platformId: id, tier: tier, displayName: 'r', createdAt: DateTime.utc(2026), config: config);
    for (final (id, tier) in [('tiktok', _byok), ('pixelfed', PlatformTier.openApi), ('deviantart', _byok), ('x', _byok), ('tumblr', _byok)]) {
      expect(adapters[id]!.rotatesRefreshTokensFor(a(id, tier)), isTrue, reason: id);
      expect(adapters[id]!.rotatesRefreshTokensFor(a(id, PlatformTier.handoff)), isFalse, reason: '$id on hand-off');
    }
    expect(adapters['x']!.rotatesRefreshTokensFor(a('x', _byok, {'authMode': 'oauth1'})), isFalse);
    // Not documented as rotating, or fall back on a stored credential.
    for (final (id, tier) in [('pinterest', _byok), ('reddit', _byok), ('bluesky', PlatformTier.openApi), ('micropub', PlatformTier.openApi), ('matrix', PlatformTier.openApi)]) {
      expect(adapters[id]!.rotatesRefreshTokensFor(a(id, tier)), isFalse, reason: id);
    }
  });
}

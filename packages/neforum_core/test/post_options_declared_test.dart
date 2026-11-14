// Gate: every PostVariant.extra key an adapter reads is declared once on its
// PlatformDescriptor.options, so no option exists in code that the user
// cannot reach (or that NEFORUM does not knowingly set itself).
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/blogs_a/ghost_adapter.dart';
import 'package:neforum_core/src/adapters/blogs_a/wordpress_adapter.dart';
import 'package:neforum_core/src/adapters/bluesky/bluesky_adapter.dart';
import 'package:neforum_core/src/adapters/threads/threads_adapter.dart';
import 'package:neforum_core/src/adapters/tiktok/tiktok_adapter.dart';
import 'package:neforum_core/src/adapters/tumblr/tumblr_adapter.dart';
import 'package:test/test.dart';

import 'support/extra_key_scan.dart';
import 'support/post_options_attribution.dart';

void main() {
  final scan = ExtraKeyScan.run();
  final adapters = builtinAdapters();
  final rows = postOptionRows(scan, adapters);

  test('the scan reads the adapters (it is not looking at an empty tree)', () {
    expect(scan.sources.keys.where((f) => f.startsWith('adapters/')), hasLength(greaterThan(50)));
    // Known reads of each pattern: a literal, a constant, extraAs, containsKey,
    // a const loop, Reddit's helper lists and the placement getter.
    final telegram = rows.where((r) => r.platform == 'telegram').map((r) => r.key).toSet();
    expect(telegram, containsAll(['silent', 'disableLinkPreview']));
    final keysOf = {for (final r in rows) '${r.platform}/${r.key}': r.readAt};
    expect(keysOf['bluesky/bluesky.linkCard'], isNotEmpty, reason: 'a static const');
    expect(keysOf['flickr/flickrContentType'], isNotEmpty, reason: 'extraAs with a const');
    expect(keysOf['micropub/syndicateTo'], isNotEmpty, reason: 'containsKey');
    expect(keysOf['pinterest/pinterestBoardSectionId'], isNotEmpty, reason: 'for (final key in const [...])');
    expect(keysOf['reddit/sendreplies'], isNotEmpty, reason: 'Reddit helper key list');
    expect(keysOf['instagram/placement'], isNotEmpty, reason: 'variant.placement');
  });

  test('every read names its key', () {
    expect(scan.unresolved, isEmpty,
        reason: 'An adapter reads PostVariant.extra with a key the scan cannot name. Read it with a literal or a '
            'const, or teach test/support/extra_key_scan.dart the new form.');
  });

  test('no option is supported in code but out of reach: every key an adapter reads is declared', () {
    final unreachable = [for (final r in rows) if (r.option == null) '${r.platform}: ${r.key} (read at ${r.readAt.join(', ')})'];
    expect(unreachable, isEmpty,
        reason: 'Declare each key on the descriptor\'s options (lib/src/adapters/network_options.dart): '
            'up front, under More options, in its own control, or internal with the reason in its help.');
  });

  test('every declared key is read by its adapter, or by the app where noted', () {
    final dead = [
      for (final r in rows)
        if (r.option != null && r.readAt.isEmpty && !(appReadOptions[r.platform]?.contains(r.key) ?? false)) '${r.platform}: ${r.key}',
    ];
    expect(dead, isEmpty, reason: 'A declared option nothing reads would be a control that does nothing.');
  });

  test('declarations are well formed', () {
    for (final a in adapters) {
      final d = a.descriptor;
      final keys = <String>{};
      for (final o in d.options) {
        final where = '${d.id}.${o.key}';
        expect(keys.add(o.key), isTrue, reason: '$where declared twice');
        for (final alias in o.aliases) {
          expect(keys.add(alias), isTrue, reason: '$where: alias $alias is another option');
        }
        expect(o.label.trim(), isNotEmpty, reason: where);
        if (o.tiers.isNotEmpty) {
          expect(o.tiers.intersection(d.tiers), isNotEmpty, reason: '$where applies to no tier ${d.id} has');
        }
        if (o.kind == PostOptionKind.choice) {
          expect(o.choices, isNotEmpty, reason: where);
          expect(o.choices.map((c) => c.value).toSet(), hasLength(o.choices.length), reason: '$where repeats a choice');
          if (o.isUserFacing && o.surface != PostOptionSurface.dedicated) {
            expect(o.defaultLabel, isNotNull, reason: '$where: say what "no choice" means');
          }
        } else {
          expect(o.choices, isEmpty, reason: where);
        }
        if (o.kind == PostOptionKind.toggle && o.isUserFacing) {
          expect(o.defaultValue, isA<bool>(), reason: '$where: a switch shows its default');
        }
        if (o.surface == PostOptionSurface.internal) {
          expect(o.help, isNotNull, reason: '$where: an internal key says why it has no control');
        }
        // Plain, direct English: no em dashes in anything the user reads.
        for (final s in [o.label, o.help, o.hint, o.gate, o.defaultLabel, ...o.choices.map((c) => c.label)]) {
          expect(s ?? '', isNot(contains('—')), reason: where);
        }
      }
    }
  });

  test('a descriptor made for an account keeps its options', () {
    for (final a in adapters) {
      for (final tier in a.descriptor.tiers) {
        final account = ConnectedAccount(
            id: 'a', platformId: a.id, tier: tier, displayName: 'a', createdAt: DateTime.utc(2026), config: const {'instance': 'https://example.org'});
        expect(a.descriptorForAccount(account).options, same(a.descriptor.options), reason: '${a.id} ${tier.name}');
      }
    }
  });

  test('a helper read is credited to the networks that reach it', () {
    final classes = {for (final a in adapters) adapterClassName(a)};
    for (final e in sharedReadOwners.entries) {
      final witness = RegExp(sharedReadWitnesses[e.key]!);
      final reaching = <String>{
        for (final a in adapters)
          if (scan.filesOf(adapterClassName(a), classes).where((f) => f != e.key).any((f) => witness.hasMatch(scan.sources[f]!))) a.id,
      };
      for (final owners in e.value.values) {
        expect(owners, reaching, reason: '${e.key}: the networks that call it changed; update sharedReadOwners');
      }
    }
  });

  test('a Pinterest board saved under the 1.4.2 key reaches the adapter (it read only pinterestBoardId)', () {
    final registry = builtinRegistry();
    final d = registry.descriptor('pinterest')!;
    final account = ConnectedAccount(
        id: 'p', platformId: 'pinterest', tier: PlatformTier.byokApi, displayName: 'p', createdAt: DateTime.utc(2026), config: const {'boardId': '1'});
    final post = Post(
      id: 'post',
      text: 'Pin',
      media: const [MediaAttachment(id: 'm', path: '/tmp/m.jpg', mimeType: 'image/jpeg', sizeBytes: 10)],
      targets: [PostTarget(accountId: 'p', overrides: const PostOverrides(extra: {'board': '987'}))],
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    final v = const VariantResolver().resolve(post, post.targets.single, d, account: account);
    expect(v.extra['pinterestBoardId'], '987');
    expect(v.extra.containsKey('board'), isFalse);
    final issues = registry.byId('pinterest')!.validate(v, account);
    expect(issues.map((i) => i.code), isNot(contains('pinterest.bad_id')));
  });

  test('the account\'s remembered options apply, and a post\'s own choice wins, under either key', () {
    final d = builtinRegistry().descriptor('reddit')!;
    final account = ConnectedAccount(
        id: 'r',
        platformId: 'reddit',
        tier: PlatformTier.byokApi,
        displayName: 'r',
        createdAt: DateTime.utc(2026),
        config: const {
          'postDefaults': {'flairId': 'account', 'sendReplies': false}
        });
    Post post(Map<String, dynamic> extra) => Post(
          id: 'post',
          text: 'Hi',
          title: 'Hi',
          targets: [PostTarget(accountId: 'r', overrides: PostOverrides(extra: extra))],
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        );
    final plain = post(const {});
    final v = const VariantResolver().resolve(plain, plain.targets.single, d, account: account);
    expect(v.extra, containsPair('flairId', 'account'));
    expect(v.extra, containsPair('sendReplies', false));
    final old = post(const {'flair_id': 'post'});
    final w = const VariantResolver().resolve(old, old.targets.single, d, account: account);
    expect(w.extra['flairId'], 'post', reason: 'the post\'s choice under the old key beats the account\'s');
  });

  test('declared choices are the values the adapters accept', () {
    final r = builtinRegistry();
    Set<String> values(String platform, String key) => r.descriptor(platform)!.option(key)!.choices.map((c) => c.value).toSet();
    expect({for (final c in r.descriptor('youtube')!.option('categoryId')!.choices) c.value: c.label}, YouTubeAdapter.categories);
    expect(values('youtube', 'privacyStatus'), YouTubeAdapter.privacyStatuses);
    expect(values('tiktok', 'privacyLevel'), TikTokAdapter.privacyLevels);
    expect(ThreadsAdapter.replyControlValues, containsAll(values('threads', 'reply_control')));
    expect(values('bluesky', 'bluesky.selfLabel'), BlueskyAdapter.selfLabels);
    expect(wordPressStatuses, containsAll(values('wordpress', 'status')));
    expect(ghostStatuses, containsAll(values('ghost', 'status')));
    expect(values('ghost', 'ghostVisibility'), ghostVisibilities);
    expect(TumblrAdapter.extraPostTypes.toSet(), values('tumblr', 'tumblrPostType'));
  });

  group('PostOption', () {
    const toggle = PostOption(key: 't', label: 'T', kind: PostOptionKind.toggle, defaultValue: false, aliases: ['old_t']);
    const choice = PostOption(key: 'c', label: 'C', kind: PostOptionKind.choice, choices: [PostOptionChoice('a', 'A')]);
    const number = PostOption(key: 'n', label: 'N', kind: PostOptionKind.number);
    const text = PostOption(key: 's', label: 'S', kind: PostOptionKind.text);
    const media = PostOption(key: 'm', label: 'M', kind: PostOptionKind.mediaSelection);

    test('coerce keeps a value of the option\'s type and refuses the rest', () {
      expect(toggle.coerce(true), isTrue);
      expect(toggle.coerce('false'), isFalse);
      expect(toggle.coerce(1), isNull);
      expect(choice.coerce(' a '), 'a');
      expect(choice.coerce('b'), isNull, reason: 'not one of the choices');
      expect(number.coerce('42'), 42);
      expect(number.coerce(42.0), 42);
      expect(number.coerce(4.5), isNull);
      expect(number.coerce('x'), isNull);
      expect(text.coerce('  '), isNull);
      expect(text.coerce(' hi '), 'hi');
      expect(text.coerce(7), '7');
      expect(media.coerce(['a', 3, '']), ['a']);
      expect(media.coerce(<Object>[]), isNull);
    });

    test('valueIn reads the key, else the first alias', () {
      expect(toggle.valueIn({'old_t': true}), isTrue);
      expect(toggle.valueIn({'old_t': true, 't': false}), isFalse);
      expect(toggle.valueIn({}), isNull);
      expect(choice.labelOf('a'), 'A');
      expect(choice.labelOf('z'), 'z');
    });

    test('a descriptor finds an option by key or alias, and lists the ones a tier can set', () {
      final telegram = builtinRegistry().descriptor('telegram')!;
      expect(telegram.option('silent')!.label, 'Send silently');
      expect(builtinRegistry().descriptor('pinterest')!.option('board')!.key, 'pinterestBoardId');
      expect(telegram.userOptionsFor(PlatformTier.handoff), isEmpty);
      expect(telegram.userOptionsFor(PlatformTier.openApi).map((o) => o.key), contains('pin'));
      expect(builtinRegistry().descriptor('misskey')!.userOptionsFor(PlatformTier.openApi).map((o) => o.key),
          isNot(contains('replyId')), reason: 'internal keys have no control');
    });
  });

  test('option keys saved by earlier versions move to the declared key', () {
    final pinterest = builtinRegistry().descriptor('pinterest')!;
    expect(canonicalOptionKeys(pinterest.options, {'board': '123'}), {'pinterestBoardId': '123'});
    final reddit = builtinRegistry().descriptor('reddit')!;
    expect(canonicalOptionKeys(reddit.options, {'flair_id': 'a', 'flairId': 'b', 'sr': 'pics'}), {'flairId': 'b', 'subreddit': 'pics'},
        reason: 'the declared key wins over an alias');
    final same = {'subreddit': 'pics'};
    expect(canonicalOptionKeys(reddit.options, same), same, reason: 'nothing to move: the same map');
  });
}

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/handoff_only/parler_adapter.dart';
import 'package:neforum_core/src/adapters/x/x_adapter.dart';
import 'package:neforum_core/src/adapters/x/x_subscription.dart';
import 'package:neforum_core/src/adapters/youtube/youtube_descriptor.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

// 1.4.4: paid plans raise limits per account (docs/paid-tiers.md).

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {...jsonHeaders, ...headers});

Post _post(String text, {List<MediaAttachment> media = const []}) => Post(
      id: 'p',
      text: text,
      media: media,
      createdAt: testNow,
      updatedAt: testNow,
      targets: const [PostTarget(accountId: 'acct-1')],
    );

PostVariant _resolve(PlatformAdapter adapter, ConnectedAccount account, Post post) =>
    const VariantResolver().resolve(post, post.targets.single, adapter.descriptorForAccount(account), account: account);

Iterable<String> _codes(List<ValidationIssue> issues) => issues.map((i) => i.code);

/// Sentences of plain Latin text, exactly [length] characters long.
String _text(int length) {
  const sentence = 'NEFORUM posts this sentence again. ';
  final b = StringBuffer();
  while (b.length < length) {
    b.write(sentence);
  }
  return b.toString().substring(0, length).trimRight().padRight(length, '.');
}

void main() {
  final x = XAdapter(clock: () => testNow);
  final parler = ParlerAdapter();
  final youtube = YouTubeAdapter();

  ConnectedAccount xAccount({PlatformTier tier = PlatformTier.byokApi, String? plan}) => fakeAccount('x',
      tier: tier,
      config: {
        if (tier == PlatformTier.byokApi) ...{'authMode': 'oauth1', 'userId': '42'},
        if (plan != null) ...AccountSubscription.entries(plan, source: SubscriptionSource.detected, at: testNow),
      });

  group('every network that declares plans', () {
    final adapters = builtinAdapters();

    test('the free plan comes first, ids are unique, and the assumed plan exists', () {
      var declared = 0;
      for (final a in adapters) {
        for (final tier in a.descriptor.tiers) {
          final plans = a.subscriptionPlansFor(tier);
          if (plans == null) continue;
          declared++;
          final where = '${a.id} ${tier.name}';
          expect(plans.tiers.first.id, SubscriptionTier.freeId, reason: where);
          expect(plans.tiers.map((t) => t.id).toSet(), hasLength(plans.tiers.length), reason: where);
          expect(plans.tierWithId(plans.assumedId), isNotNull, reason: where);
          for (final t in plans.tiers) {
            expect(t.label.trim(), isNotEmpty, reason: where);
            expect(t.summary.trim(), isNotEmpty, reason: where);
            expect(t.summary, isNot(contains('—')), reason: 'no em dashes in user-facing text ($where)');
          }
          expect(plans.help, isNot(contains('—')), reason: where);
        }
      }
      expect(declared, 4, reason: 'X (API, hand-off), Parler, YouTube (API); see docs/paid-tiers.md');
    });

    test('a plan the person chooses is asked on the connect form; a detected one is not', () {
      for (final a in adapters) {
        for (final spec in a.connectSpecs) {
          final plans = a.subscriptionPlansFor(spec.tier);
          final field = spec.fields.where((f) => f.key == AccountSubscription.tierKey).firstOrNull;
          final where = '${a.id} ${spec.tier.name}';
          if (plans == null || plans.detected) {
            expect(field, isNull, reason: where);
          } else {
            expect(field, isNotNull, reason: '$where: the form must ask for the plan');
            expect(field!.kind, plans.isSwitch ? FieldKind.boolean : FieldKind.select, reason: where);
            expect(field.required, isFalse, reason: where);
          }
        }
      }
    });

    test('an account of a network without plans has no plan', () {
      expect(builtinAdapters().firstWhere((a) => a.id == 'bluesky').subscriptionTierOf(fakeAccount('bluesky')), isNull);
    });
  });

  group('SubscriptionPlans', () {
    test('fromInput reads a switch, an id or a label, and nothing else', () {
      expect(ParlerAdapter.plans.fromInput('true')?.id, 'premium');
      expect(ParlerAdapter.plans.fromInput('FALSE')?.id, 'free');
      expect(ParlerAdapter.plans.fromInput('premium')?.id, 'premium');
      expect(ParlerAdapter.plans.fromInput(''), isNull);
      expect(ParlerAdapter.plans.fromInput('gold'), isNull);
      expect(XSubscription.handoff.fromInput('X Premium+')?.id, 'premium_plus');
      expect(XSubscription.handoff.fromInput('premium_plus')?.id, 'premium_plus');
      expect(XSubscription.handoff.fromInput('true'), isNull, reason: 'a list is not a switch');
    });

    test('a list field starts on the free plan and offers every plan by name', () {
      final f = XSubscription.handoff.connectField;
      expect((f.kind, f.defaultValue), (FieldKind.select, 'X free'));
      expect(f.options, [for (final t in XSubscription.tiers) t.label]);
    });

    test('choosing a plan clears the date the network last reported one', () {
      final detected = xAccount(plan: 'premium');
      expect(AccountSubscription.sourceOf(detected), SubscriptionSource.detected);
      expect(AccountSubscription.checkedAt(detected), testNow);
      final chosen = x.withSubscriptionTier(detected, SubscriptionTier.freeId);
      expect(AccountSubscription.storedTierId(chosen), 'free');
      expect(AccountSubscription.sourceOf(chosen), SubscriptionSource.chosen);
      expect(AccountSubscription.checkedAt(chosen), isNull);
      expect(chosen.config['userId'], '42', reason: 'the rest of the config stays');
    });

    test('the plan survives the account\'s JSON (Sync, backups)', () {
      final a = x.withSubscriptionTier(xAccount(tier: PlatformTier.handoff), 'premium');
      final back = ConnectedAccount.fromJson(jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
      expect(x.subscriptionTierOf(back)?.label, 'X Premium');
    });
  });

  group('X', () {
    test('detection: subscription_type first, then verified_type', () {
      String? id(Object? sub, [Object? verified]) => XSubscription.tierIdFromProfile(subscriptionType: sub, verifiedType: verified);
      expect(id('None'), 'free');
      expect(id('Basic'), 'basic');
      expect(id('Premium'), 'premium');
      expect(id('PremiumPlus'), 'premium_plus');
      expect(id('premium_plus'), 'premium_plus', reason: 'case and separators do not matter');
      expect(id('Ultra'), 'x_subscription', reason: 'a newer plan X does not document yet is still paid');
      expect(id('None', 'blue'), 'free', reason: 'subscription_type decides when X sends it');
      expect(id(null, 'business'), 'verified_organization');
      expect(id(null, 'government'), 'verified_organization');
      expect(id(null, 'blue'), 'x_subscription');
      expect(id(null, 'none'), 'free');
      expect(id(null, null), isNull, reason: 'nothing to go on: nothing is stored');
      expect(id('', ''), isNull);
    });

    test('a free account is 280 characters and 20 minutes; every paid plan 25,000 and 125 minutes, 16 GB', () {
      final free = x.descriptorForAccount(xAccount());
      expect(free.text.maxLength, 280);
      expect(free.media.videoMaxSeconds, 20 * 60);
      expect(free.media.videoMaxBytes, 8 * 1024 * 1024 * 1024);
      for (final plan in XSubscription.tiers.where((t) => !t.isFree)) {
        for (final tier in [PlatformTier.byokApi, PlatformTier.handoff]) {
          final d = x.descriptorForAccount(xAccount(tier: tier, plan: plan.id));
          expect(d.text.maxLength, 25000, reason: '${plan.id} ${tier.name}');
          expect(d.text.counting, CountingRule.weightedX, reason: 'X still weighs the characters');
          expect(d.media.videoMaxSeconds, 125 * 60, reason: plan.id);
          expect(d.media.videoMaxBytes, 16 * 1024 * 1024 * 1024, reason: plan.id);
          expect(d.options, same(x.descriptor.options), reason: 'the declared options stay the same');
        }
      }
      // The media capacity still follows the account: 20 per post on the API, 4 by hand-off.
      expect(x.descriptorForAccount(xAccount(plan: 'premium')).media.maxItems, 20);
      expect(x.descriptorForAccount(xAccount(tier: PlatformTier.handoff, plan: 'premium')).media.maxImages, 4);
    });

    test('a 25,000-character post is one post with X Premium and a thread without', () {
      final post = _post(_text(25000));
      final premium = _resolve(x, xAccount(plan: 'premium'), post);
      expect(premium.isThread, isFalse);
      expect(premium.text, post.text);
      expect(_codes(x.validate(premium, xAccount(plan: 'premium'))), allOf(isNot(contains('text.too_long')), contains('x.long_post')));

      final free = _resolve(x, xAccount(), post);
      expect(free.isThread, isTrue);
      expect(free.threadParts.length, greaterThan(90));
      for (final part in free.threadParts) {
        expect(TextCounter.count(part, x.descriptor.text), lessThanOrEqualTo(280));
      }
      expect(_codes(x.validate(free, xAccount())), isNot(contains('x.long_post')));

      // One character over the paid limit: a thread again, each part within 25,000.
      final over = _resolve(x, xAccount(plan: 'premium_plus'), _post(_text(25001)));
      expect(over.isThread, isTrue);
      for (final part in over.threadParts) {
        expect(TextCounter.count(part, x.descriptorForAccount(xAccount(plan: 'premium_plus')).text), lessThanOrEqualTo(25000));
      }
    });

    test('the rules check uses the account\'s plan for text and video', () {
      final long = PostVariant(text: _text(1000));
      expect(_codes(x.validate(long, xAccount())), contains('text.too_long'));
      expect(_codes(x.validate(long, xAccount(plan: 'basic'))), isNot(contains('text.too_long')));
      final hourVideo = PostVariant(text: 'hi', media: [fakeVideo(durationMs: 60 * 60 * 1000)]);
      expect(_codes(x.validate(hourVideo, xAccount())), contains('media.video_too_long'));
      expect(_codes(x.validate(hourVideo, xAccount(plan: 'premium'))), isNot(contains('media.video_too_long')));
      // A short post on a paid plan says nothing about long posts.
      expect(_codes(x.validate(const PostVariant(text: 'hi'), xAccount(plan: 'premium'))), isNot(contains('x.long_post')));
    });

    Map<String, Object> me({Object? sub, Object? verified}) => {
          'data': {
            'id': '42',
            'name': 'Alice',
            'username': 'alice',
            if (sub != null) 'subscription_type': sub,
            if (verified != null) 'verified_type': verified,
          },
        };
    const keyInput = {
      'api_key': 'test-api-key',
      'api_key_secret': 'test-api-key-secret',
      'access_token': '42-test-access-token',
      'access_token_secret': 'test-access-token-secret',
    };

    test('connect stores the plan X reports, with the date; nothing when X sends no plan fields', () async {
      final calls = <http.Request>[];
      final ctx = testContext(handler: (r) async {
        calls.add(r);
        return _json(me(sub: 'PremiumPlus', verified: 'blue'), 200, {'x-access-level': 'read-write'});
      });
      final r = await x.connect(PlatformTier.byokApi, keyInput, ctx);
      expect(calls.single.url.queryParameters['user.fields']?.split(','), containsAll(['subscription_type', 'verified_type']),
          reason: 'one call reads the profile and the plan');
      expect(r.account.config, {
        'authMode': 'oauth1',
        'userId': '42',
        'subscriptionTier': 'premium_plus',
        'subscriptionSource': 'detected',
        'subscriptionCheckedAt': testNow.toIso8601String(),
      });
      expect(x.subscriptionTierOf(r.account)?.label, 'X Premium+');
      expect(x.descriptorForAccount(r.account).text.maxLength, 25000);

      final none = await x.connect(
          PlatformTier.byokApi, keyInput, testContext(handler: (r) async => _json(me(), 200, {'x-access-level': 'read-write'})));
      expect(none.account.config, {'authMode': 'oauth1', 'userId': '42'});
      expect(x.subscriptionTierOf(none.account)?.id, 'free', reason: 'unknown is free on X');
    });

    test('readSubscriptionTier asks X again; a refusal is an AdapterException', () async {
      final account = xAccount();
      const secrets = {
        'oauth1_consumer_key': 'k',
        'oauth1_consumer_secret': 's',
        'oauth1_token': '42-t',
        'oauth1_token_secret': 'ts',
      };
      expect(x.canReadSubscriptionTier(account), isTrue);
      expect(x.canReadSubscriptionTier(xAccount(tier: PlatformTier.handoff)), isFalse);
      final got = await x.readSubscriptionTier(account, secrets, testContext(handler: (r) async => _json(me(sub: 'Basic'))));
      expect(got?.id, 'basic');
      expect(await x.readSubscriptionTier(account, secrets, testContext(handler: (r) async => _json(me()))), isNull);
      await expectLater(
        x.readSubscriptionTier(account, secrets, testContext(handler: (r) async => _json({'title': 'Unauthorized'}, 401))),
        throwsA(isA<AdapterException>().having((e) => e.error.kind, 'kind', PublishErrorKind.auth)),
      );
      await expectLater(x.readSubscriptionTier(account, const {}, testContext(handler: (r) async => _json(me()))),
          throwsA(isA<AdapterException>()));
    });

    test('hand-off accounts keep the plan chosen on the form', () async {
      final ctx = testContext(handler: (r) async => throw StateError('no network for hand-off'));
      final premium = await x.connect(PlatformTier.handoff, {'handle': 'alice', 'subscriptionTier': 'X Premium'}, ctx);
      expect(AccountSubscription.storedTierId(premium.account), 'premium');
      expect(AccountSubscription.sourceOf(premium.account), SubscriptionSource.chosen);
      expect(x.descriptorForAccount(premium.account).text.maxLength, 25000);
      final free = await x.connect(PlatformTier.handoff, {'handle': 'alice', 'subscriptionTier': 'X free'}, ctx);
      expect(x.descriptorForAccount(free.account).text.maxLength, 280);
      final none = await x.connect(PlatformTier.handoff, {'handle': 'alice'}, ctx);
      expect(AccountSubscription.storedTierId(none.account), isNull);
    });
  });

  group('Parler: 1.4.3 Premium switch', () {
    test('an account saved by 1.4.3 keeps Premium (premium: true, or "true" from the form)', () {
      for (final v in <Object>[true, 'true', 'True']) {
        final old = fakeAccount('parler', tier: PlatformTier.handoff, config: {'label': 'Me', 'premium': v});
        expect(parler.subscriptionTierOf(old)?.id, 'premium', reason: '$v');
        expect(parler.descriptorForAccount(old).text.maxLength, 2000, reason: '$v');
      }
      for (final v in <Object>[false, 'false']) {
        final old = fakeAccount('parler', tier: PlatformTier.handoff, config: {'premium': v});
        expect(parler.subscriptionTierOf(old)?.id, 'free', reason: '$v');
      }
      expect(parler.subscriptionTierOf(fakeAccount('parler', tier: PlatformTier.handoff))?.id, 'free');
    });

    test('the new plan wins over the old switch, and changing it keeps the switch in step', () {
      final old = fakeAccount('parler', tier: PlatformTier.handoff, config: {'label': 'Me', 'premium': true});
      final off = parler.withSubscriptionTier(old, SubscriptionTier.freeId);
      expect(off.config, {'label': 'Me', 'subscriptionTier': 'free', 'subscriptionSource': 'chosen'},
          reason: 'a 1.4.3 device reading this account sees no Premium either');
      expect(ParlerAdapter.isPremium(off), isFalse);
      expect(parler.descriptorForAccount(off).text.maxLength, 300);
      final on = parler.withSubscriptionTier(off, ParlerAdapter.premiumTierId);
      expect(on.config['premium'], isTrue);
      expect(parler.descriptorForAccount(on).text.maxLength, 2000);
      // Validation follows the stored plan.
      expect(_codes(parler.validate(PostVariant(text: _text(1500)), on)), isNot(contains('text.too_long')));
      expect(_codes(parler.validate(PostVariant(text: _text(1500)), off)), contains('text.too_long'));
    });
  });

  group('YouTube long uploads', () {
    ConnectedAccount channel(String? plan) => fakeAccount('youtube',
        tier: PlatformTier.byokApi,
        config: {
          'clientId': 'c.apps.googleusercontent.com',
          'channelId': 'UC1',
          if (plan != null) ...AccountSubscription.entries(plan, source: SubscriptionSource.detected, at: testNow),
        });
    final twentyMinutes = PostVariant(text: 'd', title: 't', media: [fakeVideo(durationMs: 20 * 60 * 1000)]);

    test('longUploadsStatus maps to the plan; nothing stored when YouTube says nothing', () {
      expect(YouTubeLongUploads.tierIdFor('allowed'), 'long_uploads');
      expect(YouTubeLongUploads.tierIdFor('eligible'), 'free');
      expect(YouTubeLongUploads.tierIdFor('disallowed'), 'free');
      expect(YouTubeLongUploads.tierIdFor(null), isNull);
    });

    test('a standard channel is held to 15 minutes; a verified or not yet read one keeps 12 hours', () {
      expect(youtube.descriptorForAccount(channel('free')).media.videoMaxSeconds, 15 * 60);
      expect(youtube.descriptorForAccount(channel('long_uploads')).media.videoMaxSeconds, 12 * 60 * 60);
      expect(youtube.descriptorForAccount(channel(null)).media.videoMaxSeconds, 12 * 60 * 60,
          reason: 'channels connected before 1.4.4 lose nothing');
      expect(_codes(youtube.validate(twentyMinutes, channel('free'))), containsAll(['media.video_too_long', 'youtube.long_uploads_off']));
      expect(_codes(youtube.validate(twentyMinutes, channel('long_uploads'))),
          allOf(isNot(contains('media.video_too_long')), isNot(contains('youtube.long_video'))));
      expect(_codes(youtube.validate(twentyMinutes, channel(null))),
          allOf(isNot(contains('media.video_too_long')), contains('youtube.long_video')));
    });

    test('hand-off accounts have no plan: YouTube itself says so when uploading', () {
      expect(youtube.subscriptionPlansFor(PlatformTier.handoff), isNull);
    });
  });
}

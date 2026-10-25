import 'package:http/http.dart' as http;
import 'package:neforum_core/neforum_core.dart';
import 'package:neforum_core/src/adapters/art/art_handoff_common.dart';
import 'package:neforum_core/src/adapters/art/artfol_adapter.dart';
import 'package:neforum_core/src/adapters/art/artstation_adapter.dart';
import 'package:neforum_core/src/adapters/art/behance_adapter.dart';
import 'package:neforum_core/src/adapters/art/cara_adapter.dart';
import 'package:neforum_core/src/adapters/art/fivehundredpx_adapter.dart';
import 'package:neforum_core/src/adapters/art/furaffinity_adapter.dart';
import 'package:neforum_core/src/adapters/art/itaku_adapter.dart';
import 'package:neforum_core/src/adapters/art/kofi_adapter.dart';
import 'package:neforum_core/src/adapters/art/newgrounds_adapter.dart';
import 'package:neforum_core/src/adapters/art/pixiv_adapter.dart';
import 'package:neforum_core/src/adapters/art/weasyl_adapter.dart';
import 'package:test/test.dart';

import '../support/test_context.dart';

/// A context whose HTTP fails the test: hand-off adapters must never call out.
AdapterContext _noHttp(List<http.Request> calls) => testContext(handler: (req) async {
      calls.add(req);
      return http.Response('unexpected', 500);
    });

final List<ArtHandoffAdapter> _all = [
  BehanceAdapter(),
  ArtStationAdapter(),
  CaraAdapter(),
  PixivAdapter(),
  ItakuAdapter(),
  NewgroundsAdapter(),
  FurAffinityAdapter(),
  WeasylAdapter(),
  KofiAdapter(),
  ArtfolAdapter(),
  FiveHundredPxAdapter(),
];

ConnectedAccount _acct(String platformId) => fakeAccount(platformId, tier: PlatformTier.handoff);

Iterable<String> _codes(List<ValidationIssue> issues) => issues.map((i) => i.code);

const _tags = ['ink', 'dragon', 'fantasy', 'sketch', 'traditional'];

/// A complete artwork post: image, title, description and five tags.
PostVariant _artwork({
  ArtworkDetails artwork = const ArtworkDetails(disallowAiTraining: false),
  List<MediaAttachment>? media,
  List<String> tags = _tags,
  String? title = 'Ink dragon',
  String text = 'A dragon in ink and wash.',
  String? contentWarning,
}) =>
    PostVariant(
      text: text,
      title: title,
      tags: tags,
      media: media ?? [fakeImage(width: 2400, height: 1800)],
      artwork: artwork,
      contentWarning: contentWarning,
    );

/// A NEFORUM text card, which is never artwork.
const MediaAttachment _card = MediaAttachment(id: 'card', path: '/tmp/card.jpg', mimeType: 'image/jpeg', sizeBytes: 64, generated: true);

void main() {
  group('every hand-off art site', () {
    test('is registered once, as an art site', () {
      final r = builtinRegistry();
      for (final a in _all) {
        expect(r.byId(a.id), isNotNull, reason: a.id);
        expect(r.descriptor(a.id)!.isArtPlatform, isTrue, reason: a.id);
      }
      expect(r.byId('fivehundredpx')!.descriptor.name, '500px');
    });

    for (final a in _all) {
      group(a.id, () {
        test('descriptor: hand-off only, art, needs media, points at its guide', () {
          final d = a.descriptor;
          expect(d.tiers, {PlatformTier.handoff});
          expect(d.defaultTier, PlatformTier.handoff);
          expect(d.categories, {PlatformCategory.art});
          expect(d.media.requiresMedia, isTrue);
          expect(d.media.maxImages, greaterThan(0));
          expect(d.personalAccountOk, isTrue);
          expect(d.setupGuide, 'docs/platforms/${a.id}.md');
          expect(d.text.supportsThreads, isFalse);
          expect(d.defaultQuotas, isEmpty);
        });

        test('connect: an optional label, no HTTP, no secrets', () async {
          final calls = <http.Request>[];
          expect(a.connectSpecs.single.fields.single.key, 'label');
          expect(a.connectSpecs.single.intro, contains('hand-off'));
          expect(a.connectSpecs.single.intro, contains('**Artwork**'));
          final r = await a.connect(PlatformTier.handoff, {'label': 'my gallery'}, _noHttp(calls));
          expect(calls, isEmpty);
          expect(r.secrets, isEmpty);
          expect(r.account.platformId, a.id);
          expect(r.account.id, startsWith('${a.id}:handoff:'));
        });

        test('publish() returns unsupported without touching the network', () async {
          final calls = <http.Request>[];
          final r = await a.publish(_artwork(), _acct(a.id), const {}, _noHttp(calls));
          expect(calls, isEmpty);
          expect(r.error!.kind, PublishErrorKind.unsupported);
        });

        test('a complete artwork post passes', () {
          final issues = a.validate(_artwork(), _acct(a.id));
          expect(issues.errors, isEmpty, reason: '${issues.errors}');
        });

        test('a post that is not artwork is refused', () {
          final v = PostVariant(text: 'Hello', title: 'Hi', media: [fakeImage()]);
          final issues = a.validate(v, _acct(a.id));
          expect(issues.errors.map((i) => i.code), contains('art.not_artwork'));
          expect(issues.firstWhere((i) => i.code == 'art.not_artwork').message, contains('Turn on Artwork'));
        });

        test('artwork without an image is refused, and a text card does not count', () {
          for (final media in [const <MediaAttachment>[], [_card]]) {
            final issues = a.validate(_artwork(media: media), _acct(a.id));
            expect(issues.errors.map((i) => i.code), contains('art.media_required'), reason: '$media');
            expect(_codes(issues), isNot(contains('media.required')), reason: 'one message, in the words of an art site');
          }
        });

        test('hand-off: numbered steps, the upload page, title and tags to copy, the work to share', () {
          final v = _artwork(media: [fakeImage(width: 2400, height: 1800), _card]);
          final plan = a.buildHandoff(v)!;
          expect(plan.platformId, a.id);
          expect(plan.instructions, startsWith('1. '));
          expect(plan.instructions.split('\n').last, matches(RegExp(r'^\d+\. ')));
          expect(plan.desktopUrl, a.uploadUrlFor(v));
          expect(plan.clipboardText, 'A dragon in ink and wash.');
          expect(plan.shareFiles.map((m) => m.id), ['img1'], reason: 'text cards never go to art sites');
          final snippets = {for (final s in plan.snippets) s.label: s.text};
          if (a.descriptor.text.titleSupported) expect(snippets['Title'], 'Ink dragon');
          expect(snippets['Tags'], isNotNull);
          expect(plan.preferred, a.appPostsWork ? HandoffMethod.shareSheet : HandoffMethod.manual);
          expect(plan.composerUrl == null, !a.opensUploadForm);
          expect(plan.mediaNote, contains(a.descriptor.name));
        });

        if (a.opensUploadForm) {
          test('with the browser extension the filled-in steps are left out', () {
            final plan = a.buildHandoff(_artwork())!;
            expect(plan.composerUrl.toString(), plan.desktopUrl);
            expect(plan.composerInstructions, contains('NEFORUM extension adds your files, title, description and tags'));
            expect(plan.composerInstructions, isNot(contains('Save media to Downloads')));
            expect(plan.composerInstructions, isNot(contains('Copy the **Title**')));
            expect(plan.instructions, contains('Save media to Downloads'));
          });
        }
      });
    }
  });

  group('Behance', () {
    final a = BehanceAdapter();

    test('adult work: tick the adult content box; AI work: list the tools', () {
      final v = _artwork(artwork: const ArtworkDetails(maturity: ArtworkMaturity.adult, aiGenerated: true));
      final plan = a.buildHandoff(v)!;
      expect(plan.instructions, contains('This project contains adult content'));
      expect(plan.instructions, contains('Tools Used'));
      expect(plan.desktopUrl, 'https://www.behance.net/portfolio/editor');
      expect(_codes(a.validate(v, _acct('behance'))), containsAll(['behance.adult_content', 'behance.ai_tools']));
      expect(a.buildHandoff(_artwork())!.instructions, isNot(contains('adult content')));
    });

    test('up to 10 tags, a cover of 808 x 632 that is not a GIF, 32 megapixels', () {
      final tags = [for (var i = 0; i < 12; i++) 'tag$i'];
      expect(a.buildHandoff(_artwork(tags: tags))!.snippets.last.text.split(', '), hasLength(10));
      expect(_codes(a.validate(_artwork(media: [fakeImage(mimeType: 'image/gif')]), _acct('behance'))), contains('behance.cover_gif'));
      expect(_codes(a.validate(_artwork(media: [fakeImage(width: 800, height: 600)]), _acct('behance'))), contains('behance.cover_size'));
      expect(a.photoFit(_acct('behance'), _artwork())!.maxPixels, 32000000);
    });
  });

  group('ArtStation', () {
    final a = ArtStationAdapter();

    test('NoAI and CreatedWithAI go in front of the tags', () {
      final v = _artwork(artwork: const ArtworkDetails(aiGenerated: true, disallowAiTraining: true), tags: const ['robot']);
      final plan = a.buildHandoff(v)!;
      expect(plan.snippets.firstWhere((s) => s.label == 'Tags').text, 'NoAI, CreatedWithAI, robot');
      expect(plan.instructions, contains('they include NoAI and CreatedWithAI'));
    });

    test('mature work: the checkbox, and a clean cover', () {
      final v = _artwork(artwork: const ArtworkDetails(maturity: ArtworkMaturity.mature));
      expect(a.buildHandoff(v)!.instructions, contains('**mature content** checkbox'));
      expect(_codes(a.validate(v, _acct('artstation'))), contains('artstation.mature'));
    });

    test('images from 400 to 10,000 pixels; clips over 25 MB need Premium', () {
      expect(_codes(a.validate(_artwork(media: [fakeImage(width: 300, height: 900)]), _acct('artstation'))), contains('artstation.image_too_small'));
      expect(_codes(a.validate(_artwork(media: [fakeImage(width: 12000, height: 900)]), _acct('artstation'))), contains('artstation.image_too_large'));
      expect(_codes(a.validate(_artwork(media: [fakeVideo(sizeBytes: 40 * 1024 * 1024)]), _acct('artstation'))), contains('artstation.video_size'));
    });
  });

  group('Cara', () {
    final a = CaraAdapter();

    test('no NSFW: adult work is refused, mature work is a warning', () {
      final adult = a.validate(_artwork(artwork: const ArtworkDetails(maturity: ArtworkMaturity.adult)), _acct('cara'));
      expect(adult.errors.map((i) => i.code), contains('cara.adult'));
      final mature = a.validate(_artwork(artwork: const ArtworkDetails(maturity: ArtworkMaturity.mature)), _acct('cara'));
      expect(mature.errors, isEmpty);
      expect(mature.warnings.map((i) => i.code), contains('cara.mature'));
    });

    test('AI work stays out of the portfolio', () {
      final v = _artwork(artwork: const ArtworkDetails(aiGenerated: true));
      expect(_codes(a.validate(v, _acct('cara'))), contains('cara.ai'));
      expect(a.buildHandoff(v)!.instructions, contains('Leave **Add to Portfolio** off'));
      expect(a.buildHandoff(_artwork())!.instructions, contains('Tick **Add to Portfolio**'));
    });

    test('phones share to the Cara app; no title field; 1,200 characters', () {
      final plan = a.buildHandoff(_artwork())!;
      expect(plan.androidPackage, 'com.caraproject.app');
      expect(plan.desktopUrl, 'https://cara.app/');
      expect(plan.instructions, contains('Click **Post** to open the composer'));
      expect(a.descriptor.text.titleSupported, isFalse);
      expect(a.descriptor.text.maxLength, 1200);
    });
  });

  group('pixiv', () {
    final a = PixivAdapter();

    test('age restriction and AI-generated follow the artwork details', () {
      String steps(ArtworkDetails d) => a.buildHandoff(_artwork(artwork: d))!.instructions;
      expect(steps(const ArtworkDetails()), contains('**Age restriction** to **All ages**.'));
      expect(steps(const ArtworkDetails(maturity: ArtworkMaturity.mature)), contains('slightly sexual content'));
      expect(steps(const ArtworkDetails(maturity: ArtworkMaturity.adult)), contains('**R-18**'));
      expect(steps(const ArtworkDetails()), contains('**AI-generated** to **No**'));
      expect(steps(const ArtworkDetails(aiGenerated: true)), contains('**AI-generated** to **Yes**'));
    });

    test('200 MB per post, tags of 30 characters, the pixiv app on Android', () {
      final big = [for (var i = 0; i < 7; i++) fakeImage(id: 'p$i', sizeBytes: 30 * 1024 * 1024)];
      expect(_codes(a.validate(_artwork(media: big), _acct('pixiv'))), contains('pixiv.post_too_large'));
      expect(_codes(a.validate(_artwork(tags: ['x' * 31]), _acct('pixiv'))), contains('pixiv.tag_too_long'));
      expect(a.buildHandoff(_artwork())!.androidPackage, 'jp.pxv.android');
      expect(a.buildHandoff(_artwork())!.desktopUrl, 'https://www.pixiv.net/illustration/create');
    });
  });

  group('Itaku', () {
    final a = ItakuAdapter();

    test('the upload page follows the files: one image, several, or a video', () {
      expect(a.uploadUrlFor(_artwork()), 'https://itaku.ee/new/image');
      expect(a.uploadUrlFor(_artwork(media: [fakeImage(id: 'a'), fakeImage(id: 'b')])), 'https://itaku.ee/new/images');
      expect(a.uploadUrlFor(_artwork(media: [fakeVideo()])), 'https://itaku.ee/new/video');
    });

    test('maturity: SFW, Questionable, NSFW', () {
      String steps(ArtworkMaturity m) => a.buildHandoff(_artwork(artwork: ArtworkDetails(maturity: m)))!.instructions;
      expect(steps(ArtworkMaturity.general), contains('**Maturity rating** to **SFW**'));
      expect(steps(ArtworkMaturity.mature), contains('**Questionable**'));
      expect(steps(ArtworkMaturity.adult), contains('**NSFW**'));
    });

    test('five tags, a short content warning, no AI images', () {
      expect(_codes(a.validate(_artwork(tags: const ['a', 'b']), _acct('itaku'))), contains('itaku.tags'));
      expect(_codes(a.validate(_artwork(contentWarning: 'x' * 31), _acct('itaku'))), contains('itaku.content_warning'));
      expect(a.validate(_artwork(artwork: const ArtworkDetails(aiGenerated: true)), _acct('itaku')).errors.map((i) => i.code), contains('itaku.ai'));
      final plan = a.buildHandoff(_artwork(contentWarning: 'blood'))!;
      expect(plan.snippets.map((s) => (s.label, s.text)), contains(('Content warning', 'blood')));
    });
  });

  group('Newgrounds', () {
    final a = NewgroundsAdapter();

    test('rating questions, 12 tags, a warning for AI art', () {
      final plan = a.buildHandoff(_artwork(artwork: const ArtworkDetails(maturity: ArtworkMaturity.adult)))!;
      expect(plan.instructions, contains('Explicit work is rated A.'));
      expect(plan.desktopUrl, 'https://www.newgrounds.com/projects/art/new');
      expect(a.descriptor.text.maxHashtags, 12);
      final ai = a.validate(_artwork(artwork: const ArtworkDetails(aiGenerated: true)), _acct('newgrounds'));
      expect(ai.warnings.map((i) => i.code), contains('newgrounds.ai'));
    });
  });

  group('Fur Affinity', () {
    final a = FurAffinityAdapter();

    test('every rating is accepted; keywords are separated by spaces', () {
      for (final m in ArtworkMaturity.values) {
        final v = _artwork(artwork: ArtworkDetails(maturity: m));
        expect(a.validate(v, _acct('furaffinity')).errors, isEmpty, reason: '$m');
        expect(a.buildHandoff(v)!.instructions, contains('Set the rating to **${maturityLabel(m)}**'));
      }
      expect(a.buildHandoff(_artwork(tags: const ['fox', 'forest']))!.snippets.last.text, 'fox forest');
      expect(_codes(a.validate(_artwork(tags: const ['fox', 'ab']), _acct('furaffinity'))), contains('furaffinity.keywords'));
    });

    test('AI-generated work is refused; one file per submission', () {
      final v = _artwork(artwork: const ArtworkDetails(aiGenerated: true));
      expect(a.validate(v, _acct('furaffinity')).errors.map((i) => i.code), contains('furaffinity.ai'));
      expect(a.descriptor.media.maxImages, 1);
    });
  });

  group('Weasyl', () {
    final a = WeasylAdapter();

    test('adult work is rated Explicit; at least 2 tags, separated by spaces', () {
      final plan = a.buildHandoff(_artwork(artwork: const ArtworkDetails(maturity: ArtworkMaturity.adult), tags: const ['otter', 'river']))!;
      expect(plan.instructions, contains('Set the rating to **Explicit**'));
      expect(plan.snippets.last.text, 'otter river');
      expect(_codes(a.validate(_artwork(tags: const ['otter']), _acct('weasyl'))), contains('weasyl.tags'));
    });
  });

  group('Ko-fi, Artfol and 500px', () {
    test('Ko-fi starts from your page; big images need Gold; explicit work is a warning', () {
      final a = KofiAdapter();
      expect(a.buildHandoff(_artwork())!.instructions, contains('**Image Post**'));
      expect(_codes(a.validate(_artwork(media: [fakeImage(sizeBytes: 30 * 1024 * 1024)]), _acct('kofi'))), contains('kofi.image_size'));
      expect(a.validate(_artwork(artwork: const ArtworkDetails(maturity: ArtworkMaturity.adult)), _acct('kofi')).warnings.map((i) => i.code),
          contains('kofi.adult'));
    });

    test('Artfol refuses AI-generated art', () {
      final a = ArtfolAdapter();
      expect(a.validate(_artwork(artwork: const ArtworkDetails(aiGenerated: true)), _acct('artfol')).errors.map((i) => i.code), contains('artfol.ai'));
    });

    test('500px: mature work is marked NSFW; photos go as JPEG', () {
      final a = FiveHundredPxAdapter();
      final v = _artwork(artwork: const ArtworkDetails(maturity: ArtworkMaturity.mature));
      expect(a.buildHandoff(v)!.instructions, contains('Turn on **NSFW**'));
      expect(_codes(a.validate(v, _acct('fivehundredpx'))), contains('fivehundredpx.nsfw'));
      expect(a.descriptor.media.imageMimeTypes, {'image/jpeg'});
    });
  });

  test('resolved through the registry, an artwork post keeps its artwork details and tags', () {
    final post = Post(
      id: 'p1',
      text: 'A dragon in ink and wash.',
      title: 'Ink dragon',
      tags: const ['#ink', 'dragon'],
      media: [fakeImage()],
      artwork: const ArtworkDetails(maturity: ArtworkMaturity.mature),
      status: PostStatus.draft,
      createdAt: testNow,
      updatedAt: testNow,
      targets: const [PostTarget(accountId: 'acct-1')],
    );
    final d = builtinRegistry().descriptor('itaku')!;
    final v = VariantResolver().resolve(post, post.targets.single, d, account: _acct('itaku'));
    expect(v.artwork!.maturity, ArtworkMaturity.mature);
    expect(v.tags, ['ink', 'dragon']);
    expect(v.text, isNot(contains('#ink')), reason: 'Itaku has a tags field');
    expect(ItakuAdapter().buildHandoff(v)!.instructions, contains('**Questionable**'));
  });
}

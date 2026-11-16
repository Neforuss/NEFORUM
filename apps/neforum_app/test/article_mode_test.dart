// 1.4.4: articles. The composer's Article mode, as state: switching between
// the plain composer and the article never loses what was written, the
// article keeps the post's short version (text, file order, paragraph
// links) in step for the social networks, the post and the composer's draft
// carry it, and a post without an article is exactly what it was before.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neforum_app/platform/clipboard_media.dart';
import 'package:neforum_app/platform/storage.dart';
import 'package:neforum_app/state/article_mode.dart';
import 'package:neforum_app/state/composer.dart';
import 'package:neforum_app/state/composer_draft.dart';
import 'package:neforum_app/state/providers.dart';
import 'package:neforum_app/state/services.dart';
import 'package:neforum_app/ui/compose/article_blocks.dart';
import 'package:neforum_app/ui/compose/article_preview.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

class _MemoryStorage implements AppStorage {
  final Map<String, Object> _json = {};
  @override
  String? get dataDir => null;
  @override
  Future<Map<String, dynamic>?> readJson(String name) async => _json[name] as Map<String, dynamic>?;
  @override
  Future<void> writeJson(String name, Object data) async => _json[name] = data;
  @override
  Future<String> saveMedia(String id, String extension, Uint8List bytes) async => 'mem://$id.$extension';
  @override
  Future<Uint8List> readMedia(String path) async => Uint8List(0);
  @override
  Future<void> deleteMedia(String path) async {}
  @override
  Future<int> mediaBytes() async => 0;
  @override
  Widget image(String path, {BoxFit fit = BoxFit.cover, double? width, double? height, int? cacheWidth}) =>
      SizedBox(width: width, height: height);
}

MediaAttachment _image(String id) => MediaAttachment(id: id, path: '/m/$id.jpg', mimeType: 'image/jpeg', sizeBytes: 10, width: 1600, height: 900);

const _text = '## Why it matters\n\nA **bold** start with a [link](https://example.org).\n\n- one\n- two\n\nThe end.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> container({List<ConnectedAccount> accounts = const []}) async {
    final s = await AppServices.create(demo: true, storage: _MemoryStorage());
    final c = ProviderContainer(overrides: [
      servicesProvider.overrideWithValue(s),
      accountListProvider.overrideWithValue(accounts),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  ComposerNotifier n(ProviderContainer c) => c.read(composerProvider.notifier);
  ComposerState s(ProviderContainer c) => c.read(composerProvider);

  group('switching modes', () {
    test('plain to article and back without a change gives the plain post back exactly', () async {
      final c = await container();
      n(c).setText(_text);
      n(c).addMedia([_image('cover'), _image('a'), _image('b')]);
      n(c).toggleParagraphMedia(1, 'a');
      final before = s(c);

      n(c).enterArticleMode();
      final doc = s(c).article!;
      expect(doc.cover?.mediaId, 'cover', reason: 'the first photo linked to no paragraph');
      expect(doc.blocks.map((b) => b.type), [
        ArticleBlockType.heading,
        ArticleBlockType.paragraph,
        ArticleBlockType.image, // a, after its paragraph
        ArticleBlockType.list,
        ArticleBlockType.paragraph,
        ArticleBlockType.image, // b, at the end
      ]);
      expect((doc.blocks[1] as ArticleParagraph).spans[1], const ArticleSpan('bold', marks: {ArticleMark.bold}));

      n(c).leaveArticleMode();
      final after = s(c);
      expect(after.article, isNull);
      expect(after.text, before.text);
      expect(after.paragraphMedia, before.paragraphMedia);
      expect([for (final m in after.media) m.id], [for (final m in before.media) m.id]);
      expect(after.revision, greaterThan(before.revision), reason: 'the plain editor puts the text back in its field');
    });

    test('an edited article comes back exactly when the text was not touched', () async {
      final c = await container();
      n(c).setText('First.\n\nSecond.');
      n(c).addMedia([_image('a'), _image('b'), _image('c')]);
      n(c).enterArticleMode();
      final doc = s(c).article!;
      final edited = doc.copyWith(
        subtitle: 'A subtitle',
        excerpt: 'Short',
        slug: 'my-slug',
        status: ArticleStatus.draft,
        clearCover: true,
        blocks: [
          doc.blocks.first,
          const ArticleGallery('g', [ArticleMediaRef('a', caption: 'One'), ArticleMediaRef('b', credit: 'Me')], caption: 'Both'),
          const ArticleQuote('q', [ArticleSpan('Said')], citation: 'Someone'),
          doc.blocks[1],
        ],
      );
      n(c).setArticle(edited);
      n(c).leaveArticleMode();
      expect(s(c).text, edited.toComposerText(), reason: 'the plain composer shows the article as text');
      n(c).enterArticleMode();
      expect(s(c).article, edited, reason: 'galleries, captions, citation and fields all come back');
    });

    test('text changed in the plain composer: the article is made again, keeping its fields and captions', () async {
      final c = await container();
      n(c).setText('First.\n\nSecond.');
      n(c).addMedia([_image('cover'), _image('a')]);
      n(c).enterArticleMode();
      final doc = s(c).article!;
      expect(doc.cover?.mediaId, 'cover');
      n(c).setArticle(doc.copyWith(
        subtitle: 'Sub',
        canonicalUrl: 'https://first.example/post',
        cover: const ArticleMediaRef('cover', caption: 'Cover caption'),
        blocks: [
          for (final b in doc.blocks)
            if (b is ArticleImage) ArticleImage(b.id, ArticleMediaRef(b.media.mediaId, caption: 'Caption of ${b.media.mediaId}')) else b,
        ],
      ));
      n(c).leaveArticleMode();
      n(c).setText('${s(c).text}\n\nA new paragraph.');
      n(c).enterArticleMode();
      final again = s(c).article!;
      expect(again.subtitle, 'Sub');
      expect(again.canonicalUrl, 'https://first.example/post');
      expect(again.cover, const ArticleMediaRef('cover', caption: 'Cover caption'));
      expect(again.blocks.whereType<ArticleImage>().map((b) => b.media), [const ArticleMediaRef('a', caption: 'Caption of a')],
          reason: 'the cover is not shown twice, and the photo keeps its caption');
      expect(again.toComposerText(), endsWith('A new paragraph.'));
    });

    test('a thread becomes one article', () async {
      final c = await container();
      n(c).setText('Part one.');
      n(c).addPart();
      n(c).setPart(1, 'Part two.');
      n(c).enterArticleMode();
      expect(s(c).additionalParts, isEmpty);
      expect(s(c).article!.toComposerText(), 'Part one.\n\nPart two.');
    });
  });

  group('the article keeps the short version in step', () {
    test('text, file order and paragraph links follow the article', () async {
      final c = await container();
      n(c).addMedia([_image('a'), _image('b'), _image('unplaced')]);
      n(c).enterArticleMode();
      n(c).setArticle(const ArticleDocument(
        cover: ArticleMediaRef('b'),
        blocks: [
          ArticleParagraph('p1', [ArticleSpan('One')]),
          ArticleImage('m1', ArticleMediaRef('a')),
          ArticleParagraph('p2', [ArticleSpan('Two')]),
        ],
      ));
      final st = s(c);
      expect(st.text, 'One\n\nTwo');
      expect([for (final m in st.media) m.id], ['b', 'a', 'unplaced'], reason: 'cover first, then the article order, then the rest');
      expect(st.paragraphMedia, {0: ['a']});
      final post = st.toPost(id: 'p', status: PostStatus.draft, now: DateTime.utc(2026));
      expect(post.article, st.article);
      expect(post.text, 'One\n\nTwo');
    });

    test('a removed file takes its blocks with it; deleted blocks leave the networks\' choices', () async {
      final c = await container();
      n(c).addMedia([_image('a')]);
      n(c).enterArticleMode();
      n(c).setArticle(const ArticleDocument(blocks: [
        ArticleParagraph('p', [ArticleSpan('Words')]),
        ArticleImage('m', ArticleMediaRef('a')),
      ]));
      n(c).setExcludedBlocks('acct', ['m', 'p']);
      n(c).removeMedia('a');
      expect(s(c).article!.blocks.map((b) => b.id), ['p']);
      expect(s(c).overrides['acct']!.excludedBlockIds, ['p'], reason: 'a new block with the id m must not start left out');
      n(c).setExcludedBlocks('acct', const []);
      expect(s(c).overrides.containsKey('acct'), isFalse);
    });

    test('the draft file and a saved post keep the article; clearing keeps Article mode', () async {
      final c = await container();
      n(c).enterArticleMode();
      n(c).setArticle(const ArticleDocument(subtitle: 'S', blocks: [ArticleHeading('h', [ArticleSpan('Title')])]));
      expect(isComposerBlank(s(c)), isFalse, reason: 'an article in the making is kept');
      final json = jsonDecode(jsonEncode(composerDraftToJson(s(c)))) as Map<String, dynamic>;
      final back = composerDraftFromJson(json)!;
      expect(back.article, s(c).article);
      expect(back.text, '## Title');

      final post = s(c).toPost(id: 'saved', status: PostStatus.draft, now: DateTime.utc(2026));
      n(c).reset();
      expect(s(c).article, isNull, reason: 'a new post starts plain');
      n(c).load(post);
      expect(s(c).article, post.article);
      n(c).clearPost();
      expect(s(c).article, const ArticleDocument());
      expect(s(c).isArticle, isTrue);
    });

    test('regression: a plain post carries no article and is unchanged', () async {
      final c = await container();
      n(c).setText('Just a post');
      n(c).addMedia([_image('a')]);
      final post = s(c).toPost(id: 'p', status: PostStatus.draft, now: DateTime.utc(2026));
      expect(post.article, isNull);
      expect(post.toJson().containsKey('article'), isFalse);
      expect(composerDraftToJson(s(c))['post'], isNot(contains('article')));
      expect(isComposerBlank(const ComposerState()), isTrue);
      n(c).setArticle(const ArticleDocument(blocks: [ArticleDivider('d')]));
      expect(s(c).article, isNull, reason: 'setArticle does nothing outside Article mode');
    });
  });

  group('networks', () {
    final wordpress = ConnectedAccount(id: 'wp', platformId: 'wordpress', tier: PlatformTier.openApi, displayName: 'Blog', createdAt: DateTime.utc(2026));
    final mastodon = ConnectedAccount(id: 'md', platformId: 'mastodon', tier: PlatformTier.openApi, displayName: 'Me', createdAt: DateTime.utc(2026));

    test('blogs get the article with its report; social networks the short version', () async {
      final c = await container(accounts: [wordpress, mastodon]);
      n(c).selectAccounts(['wp', 'md']);
      n(c).setTitle('Title');
      n(c).enterArticleMode();
      n(c).setArticle(const ArticleDocument(subtitle: 'Sub', blocks: [
        ArticleHeading('h', [ArticleSpan('Head')]),
        ArticleParagraph('p', [ArticleSpan('Body '), ArticleSpan('bold', marks: {ArticleMark.bold})]),
      ]));
      final previews = c.read(composerPreviewsProvider);
      final wp = previews.singleWhere((p) => p.account.id == 'wp');
      final md = previews.singleWhere((p) => p.account.id == 'md');
      expect(wp.variant.hasArticle, isTrue);
      expect(ArticleRenderer.reportFor(wp.variant, wp.descriptor, tier: wp.account.tier).issues.map((i) => i.field), contains('subtitle'),
          reason: 'WordPress has no subtitle field');
      expect(md.variant.hasArticle, isFalse);
      expect(md.variant.text, contains('Head'));

      n(c).setExcludedBlocks('wp', ['h']);
      final again = c.read(composerPreviewsProvider).singleWhere((p) => p.account.id == 'wp');
      expect(again.variant.article!.blocks.map((b) => b.id), ['p']);
    });

    test('X gets the short version until "Post as an X Article" is on, and its note says how', () async {
      final x = ConnectedAccount(id: 'x', platformId: 'x', tier: PlatformTier.byokApi, displayName: 'Me', createdAt: DateTime.utc(2026));
      final c = await container(accounts: [wordpress, x]);
      n(c).selectAccounts(['wp', 'x']);
      n(c).setTitle('Title');
      n(c).enterArticleMode();
      n(c).setArticle(const ArticleDocument(blocks: [ArticleParagraph('p', [ArticleSpan('Body')])]));
      var preview = c.read(composerPreviewsProvider).singleWhere((p) => p.account.id == 'x');
      expect(preview.variant.hasArticle, isFalse);
      expect(articleShortVersionNote(preview, articleMode: true), contains('Post as an X Article'));
      n(c).setOverride('x', PostOverrides(extra: {c.read(registryProvider).descriptor('x')!.articleOptionKey!: true}));
      preview = c.read(composerPreviewsProvider).singleWhere((p) => p.account.id == 'x');
      expect(preview.variant.hasArticle, isTrue);
      expect(articleShortVersionNote(preview, articleMode: true), isNull, reason: 'its preview shows the article section instead');
    });
  });

  group('helpers', () {
    test('slugFromTitle', () {
      expect(slugFromTitle('Hello, World! Ça va?'), 'hello-world-ca-va');
      expect(slugFromTitle('  '), '');
      expect(slugFromTitle('Ünïcödé — 2026'), 'unicode-2026');
      expect(slugFromTitle('word ' * 40).length, lessThanOrEqualTo(80));
    });

    test('takesArticle: blogs yes, X (opt-in) and social networks no', () async {
      final c = await container();
      final r = c.read(registryProvider);
      expect(takesArticle(r.descriptor('wordpress')!), isTrue);
      expect(takesArticle(r.descriptor('substack')!), isTrue);
      expect(takesArticle(r.descriptor('x')!), isFalse);
      expect(takesArticle(r.descriptor('mastodon')!), isFalse);
    });

    test('marks: wrap, unwrap, insert at the cursor', () {
      final t = TextEditingController(text: 'say hello now');
      t.selection = const TextSelection(baseOffset: 4, extentOffset: 9);
      toggleArticleMark(t, '**');
      expect(t.text, 'say **hello** now');
      expect(t.selection.textInside(t.text), 'hello');
      toggleArticleMark(t, '**');
      expect(t.text, 'say hello now', reason: 'pressing it again takes the mark away');
      toggleArticleMark(t, '*');
      expect(t.text, 'say *hello* now');
      t.selection = const TextSelection.collapsed(offset: 0);
      toggleArticleMark(t, '`');
      expect(t.text, '``say *hello* now');
      expect(t.selection.baseOffset, 1);
    });

    test('links: the selection becomes the words; with none, the bare address', () {
      final t = TextEditingController(text: 'read this');
      t.selection = const TextSelection(baseOffset: 5, extentOffset: 9);
      insertArticleLink(t, 'https://example.org');
      expect(t.text, 'read [this](https://example.org)');
      expect(articleInlineFromMarkup(t.text).last, const ArticleSpan('this', link: 'https://example.org'));
      final u = TextEditingController(text: 'go ');
      u.selection = const TextSelection.collapsed(offset: 3);
      insertArticleLink(u, 'https://example.org');
      expect(u.text, 'go https://example.org');
    });

    test('block text as the editor shows it reads back as the block', () {
      const blocks = <ArticleBlock>[
        ArticleParagraph('p', [ArticleSpan('a '), ArticleSpan('b', marks: {ArticleMark.italic})]),
        ArticleHeading('h', [ArticleSpan('Head')], level: 3),
        ArticleQuote('q', [ArticleSpan('Q')], citation: 'C'),
        ArticleList('l', [
          [ArticleSpan('one')],
          [ArticleSpan('two', marks: {ArticleMark.bold})],
        ], ordered: true),
        ArticleCode('c', 'x = **1**', language: 'py'),
      ];
      for (final b in blocks) {
        expect(articleBlockWithMarkup(b, articleBlockMarkup(b)!), b, reason: b.id);
      }
      final turned = articleBlockConverted(blocks[0], ArticleBlockType.heading);
      expect(turned, isA<ArticleHeading>());
      expect(articleBlockMarkup(turned), 'a *b*');
    });

    test('Windows "HTML Format": offsets point at the document and the fragment', () {
      const html = '<h2>Héllo</h2><p>a &amp; b</p>';
      final bytes = ClipboardMedia.cfHtml(html);
      final s = utf8.decode(bytes.sublist(0, bytes.length - 1));
      int field(String name) => int.parse(RegExp('$name:(\\d+)').firstMatch(s)!.group(1)!);
      final raw = bytes.sublist(0, bytes.length - 1);
      expect(utf8.decode(raw.sublist(field('StartFragment'), field('EndFragment'))), html);
      expect(utf8.decode(raw.sublist(field('StartHTML'), field('EndHTML'))), startsWith('<html>'));
      expect(field('EndHTML'), raw.length);
      expect(bytes.last, 0);
    });
  });
}

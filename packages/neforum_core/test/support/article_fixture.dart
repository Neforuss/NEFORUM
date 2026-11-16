/// A fixed rich article for the serializer and adapter tests: every block
/// type, every mark, every field.
library;

import 'package:neforum_core/neforum_core.dart';

import 'test_context.dart';

MediaAttachment fakeAudio({String id = 'a1'}) => MediaAttachment(
      id: id,
      path: '/tmp/$id.mp3',
      mimeType: 'audio/mpeg',
      sizeBytes: 4096,
      durationMs: 61000,
      fileName: '$id.mp3',
    );

/// The files of [richArticle]: a cover, a photo, three gallery photos, a
/// video and a sound file.
List<MediaAttachment> richMedia() => [
      fakeImage(id: 'c1', altText: 'Cover alt'),
      fakeImage(id: 'i1', altText: 'Own alt'),
      fakeImage(id: 'g1', altText: 'G1'),
      fakeImage(id: 'g2', altText: 'G2'),
      fakeImage(id: 'g3', altText: null),
      fakeVideo(id: 'v1'),
      fakeAudio(),
    ];

const ArticleDocument richArticle = ArticleDocument(
  subtitle: 'A subtitle',
  cover: ArticleMediaRef('c1', caption: 'Cover caption'),
  excerpt: 'The excerpt',
  slug: 'rich-article',
  canonicalUrl: 'https://origin.example/rich',
  blocks: [
    ArticleHeading('h', [ArticleSpan('Intro & <setup>')], level: 2),
    ArticleParagraph('p1', [
      ArticleSpan('Plain '),
      ArticleSpan('bold', marks: {ArticleMark.bold}),
      ArticleSpan(', '),
      ArticleSpan('italic', marks: {ArticleMark.italic}),
      ArticleSpan(', '),
      ArticleSpan('code()', marks: {ArticleMark.code}),
      ArticleSpan(' and '),
      ArticleSpan('a link', link: 'https://example.com/a?b=1&c=2'),
      ArticleSpan(' *not emphasis* 2 < 3\nnext line'),
    ]),
    ArticleImage('img', ArticleMediaRef('i1', caption: 'A caption', altText: 'Ref alt', credit: 'Jane Doe')),
    ArticleGallery('gal', [ArticleMediaRef('g1'), ArticleMediaRef('g2'), ArticleMediaRef('g3')], caption: 'Three photos'),
    ArticleHeading('h3', [ArticleSpan('Details')], level: 3),
    ArticleVideo('vid', ArticleMediaRef('v1', caption: 'The video')),
    ArticleAudio('aud', ArticleMediaRef('a1', caption: 'The track')),
    ArticleEmbed('emb', 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
    ArticleQuote('q', [ArticleSpan('To be or not to be.')], citation: 'Hamlet'),
    ArticleList('ul', [
      [ArticleSpan('first')],
      [ArticleSpan('second', marks: {ArticleMark.bold})],
    ]),
    ArticleList('ol', [
      [ArticleSpan('three')],
      [ArticleSpan('four')],
    ], ordered: true, start: 3),
    ArticleCode('code', 'void main() {\n  print("```");\n}', language: 'dart'),
    ArticleDivider('hr'),
    ArticleParagraph('end', [ArticleSpan('The end. See https://example.org/x_y.')]),
  ],
);

/// [richMedia] uploaded: `https://cdn.example.test/<id>`, numbered media ids
/// from 101 (WordPress-style).
ArticleAssets richAssets({Object? Function(int i, MediaAttachment m)? remoteId}) {
  final media = richMedia();
  return ArticleAssets([
    for (var i = 0; i < media.length; i++)
      ArticleAsset(media[i], url: 'https://cdn.example.test/${media[i].id}', remoteId: remoteId == null ? 101 + i : remoteId(i, media[i])),
  ]);
}

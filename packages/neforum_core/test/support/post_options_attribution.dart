import 'package:neforum_core/neforum_core.dart';

import 'extra_key_scan.dart';

/// Helper files whose extra reads belong to some of their importers only:
/// helper file -> key -> the platforms that really read it.
///
/// `withAudioLinks` reads `linkTitle` and `linkDescription` only with
/// `linkCard: true`, which only Tumblr passes. `bodyHtml` reads `html` and
/// `format`, and only WordPress and Ghost call it. [sharedReadWitnesses]
/// holds the call that makes a platform an owner, and
/// post_options_declared_test.dart checks the owners against it.
const Map<String, Map<String, Set<String>>> sharedReadOwners = {
  'adapters/audio_links.dart': {
    'linkTitle': {'tumblr'},
    'linkDescription': {'tumblr'},
  },
  'adapters/blogs_a/blog_common.dart': {
    'html': {'wordpress', 'ghost'},
    'format': {'wordpress', 'ghost'},
  },
};

/// For each file of [sharedReadOwners]: the call in an adapter's own files
/// that reaches its reads.
const Map<String, String> sharedReadWitnesses = {
  'adapters/audio_links.dart': r'linkCard:\s*true',
  'adapters/blogs_a/blog_common.dart': r'\b(?:bodyHtml|wantsRawHtml)\(',
};

/// Keys a descriptor declares that no adapter reads, because the app reads
/// them: platform -> keys.
const Map<String, Set<String>> appReadOptions = {
  // A words-only post goes as text or with its text card: the app decides
  // which media the target gets (apps/neforum_app/lib/media/text_card.dart).
  'youtube_posts': {'textCardChoice'},
};

/// One key of one network: where the adapter reads it and how it is declared.
class PostOptionRow {
  PostOptionRow(this.platform, this.key, this.option, this.readAt);
  final String platform;
  final String key;
  final PostOption? option;
  final List<String> readAt;

  String get where => switch (option?.surface) {
        null => 'NOT DECLARED',
        PostOptionSurface.main => 'up front',
        PostOptionSurface.more => 'more options',
        PostOptionSurface.dedicated => 'own control',
        PostOptionSurface.internal => 'internal',
      };
}

/// The adapter's class name, as the source declares it.
String adapterClassName(PlatformAdapter a) => a.runtimeType.toString();

/// Every key each adapter reads (from [scan]) and every option its
/// descriptor declares, one row per network and key, in registry order.
List<PostOptionRow> postOptionRows(ExtraKeyScan scan, List<PlatformAdapter> adapters) {
  final classes = {for (final a in adapters) adapterClassName(a)};
  final rows = <PostOptionRow>[];
  for (final a in adapters) {
    final d = a.descriptor;
    final reads = scan.keysOf(adapterClassName(a), d.id, classes, sharedOwners: sharedReadOwners);
    final keys = <String>{...reads.keys, ...d.options.map((o) => o.key)};
    for (final k in keys) {
      final declared = d.option(k);
      rows.add(PostOptionRow(d.id, k, declared, (reads[k] ?? const []).toSet().toList()..sort()));
    }
  }
  return rows;
}

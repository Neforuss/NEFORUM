import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/text_card.dart';
import 'composer.dart';
import 'providers.dart';
import 'settings.dart';

/// File in the data folder holding the post being written.
const String kComposerDraftFile = 'composer.json';

/// Keeps the post in the composer across restarts: written to
/// [kComposerDraftFile] a moment after every change, put back when NEFORUM
/// starts, and cleared as soon as the composer is empty again, which is what
/// publishing or scheduling the post (or saving it as a draft) does. Quitting
/// NEFORUM, tray included, keeps it. Not used in the demo workspace.
///
/// Watched by the app shell, which keeps it alive.
final composerDraftKeeperProvider = Provider<void>((ref) {
  final services = ref.watch(servicesProvider);
  if (services.demo) return;
  Timer? pending;
  var restored = false;

  Future<void> write(ComposerState c) async {
    try {
      await services.storage.writeJson(kComposerDraftFile, isComposerBlank(c) ? const <String, dynamic>{} : composerDraftToJson(c));
    } on Object catch (e) {
      debugPrint('Could not keep the post being written: $e');
    }
  }

  ref.listen<ComposerState>(composerProvider, (prev, next) {
    if (!restored) return;
    pending?.cancel();
    pending = Timer(const Duration(milliseconds: 300), () => write(next));
  });
  ref.onDispose(() => pending?.cancel());

  () async {
    try {
      final j = await services.storage.readJson(kComposerDraftFile);
      final c = j == null ? null : composerDraftFromJson(j);
      // Only into an untouched composer: never over something being typed.
      if (c != null && isComposerBlank(ref.read(composerProvider))) {
        ref.read(composerProvider.notifier).restore(c);
      }
    } on Object catch (e) {
      debugPrint('Could not restore the post being written: $e');
    } finally {
      restored = true;
    }
  }();
});

/// Nothing worth keeping: no words, title, link, photos or poll, and not an
/// edit of a saved post.
bool isComposerBlank(ComposerState c) => c.isEmpty && c.poll == null && c.editingPostId == null;

@visibleForTesting
Map<String, dynamic> composerDraftToJson(ComposerState c) => {
      'v': 1,
      'post': c.toPost(id: c.editingPostId ?? 'composer', status: PostStatus.draft, now: DateTime.now()).toJson(),
      if (c.editingPostId != null) 'editingPostId': c.editingPostId,
      if (c.textCardTheme != null) 'textCardTheme': c.textCardTheme!.name,
      if (c.textCardFont != null) 'textCardFont': c.textCardFont!.name,
      if (c.textCardBranded.isNotEmpty) 'textCardBranded': c.textCardBranded,
      if (c.captionOnPhoto.isNotEmpty) 'captionOnPhoto': c.captionOnPhoto,
      if (c.differentiate) 'differentiate': true,
      // Kept even while empty, so an added part survives a restart.
      if (c.additionalParts.isNotEmpty) 'additionalParts': c.additionalParts,
      if (c.textCardAlignment != null) 'textCardAlignment': c.textCardAlignment!.name,
      if (c.textCardHandle.isNotEmpty) 'textCardHandle': c.textCardHandle,
      if (c.captionStyle != null) 'captionStyle': c.captionStyle,
      if (c.textCardBackground != null) 'textCardBackground': c.textCardBackground,
    };

/// Null when [j] holds no post (cleared, or from a newer NEFORUM).
@visibleForTesting
ComposerState? composerDraftFromJson(Map<String, dynamic> j) {
  final raw = j['post'];
  if (raw is! Map || (j['v'] as int? ?? 0) > 1) return null;
  final p = Post.fromJson(Map<String, dynamic>.from(raw));
  Map<String, bool> flags(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value == true} : const {};
  return ComposerState(
    editingPostId: j['editingPostId'] as String?,
    text: p.text,
    title: p.title,
    link: p.link,
    media: p.media,
    contentWarning: p.contentWarning,
    sensitive: p.sensitive,
    visibility: p.visibility,
    tags: p.tags,
    selected: p.targets.map((t) => t.accountId).toSet(),
    overrides: {for (final t in p.targets) if (!t.overrides.isEmpty) t.accountId: t.overrides},
    scheduledAt: p.scheduledAt,
    textCardTheme: TextCardTheme.values.asNameMap()[j['textCardTheme']],
    textCardFont: TextCardFont.values.asNameMap()[j['textCardFont']],
    textCardBranded: flags(j['textCardBranded']),
    captionOnPhoto: flags(j['captionOnPhoto']),
    poll: p.poll,
    differentiate: j['differentiate'] == true,
    additionalParts: (j['additionalParts'] as List?)?.cast<String>() ?? p.additionalParts,
    artwork: p.artwork,
    textCardAlignment: TextCardAlignment.values.asNameMap()[j['textCardAlignment']],
    textCardHandle: flags(j['textCardHandle']),
    captionStyle: j['captionStyle'] is Map ? Map<String, dynamic>.from(j['captionStyle'] as Map) : null,
    textCardBackground: j['textCardBackground'] is Map ? Map<String, dynamic>.from(j['textCardBackground'] as Map) : null,
  );
}

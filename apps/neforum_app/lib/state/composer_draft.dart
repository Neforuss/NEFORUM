import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/text_card.dart';
import '../platform/storage.dart';
import 'composer.dart';
import 'providers.dart';
import 'settings.dart';

/// File in the data folder holding the post being written.
const String kComposerDraftFile = 'composer.json';

/// Keeps the post in the composer across restarts: written to
/// [kComposerDraftFile] a moment after every change and put back when
/// NEFORUM starts. When the composer becomes empty (the post was published,
/// scheduled or saved as a draft, or the user started over) the file is
/// emptied at once, without the usual pause, so a posted post never comes
/// back after a restart. Quitting NEFORUM, tray included, keeps an unsent
/// post, and a change still waiting to be written is written when the
/// keeper goes away. Null in the demo workspace, which keeps nothing.
///
/// Watched by the app shell, which keeps it alive.
final composerDraftKeeperProvider = Provider<ComposerDraftKeeper?>((ref) {
  final services = ref.watch(servicesProvider);
  if (services.demo) return null;
  final keeper = ComposerDraftKeeper(services.storage);
  ref.listen<ComposerState>(composerProvider, (prev, next) => keeper.changed(next));
  ref.onDispose(() => unawaited(keeper.flush()));

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
      keeper.restored = true;
    }
  }();
  return keeper;
});

/// Writes the composer to [kComposerDraftFile] for
/// [composerDraftKeeperProvider].
class ComposerDraftKeeper {
  ComposerDraftKeeper(this._storage);

  final AppStorage _storage;
  Timer? _pending;
  ComposerState? _unsaved;
  Future<void> _lastWrite = Future<void>.value();

  /// False until the file was read at startup: nothing is written before
  /// that, so an empty composer never overwrites a post waiting to be put
  /// back.
  bool restored = false;

  /// The composer changed: written 300 ms after the last change, or at once
  /// when it is empty.
  void changed(ComposerState c) {
    if (!restored) return;
    _unsaved = c;
    _pending?.cancel();
    if (isComposerBlank(c)) {
      unawaited(flush());
    } else {
      _pending = Timer(const Duration(milliseconds: 300), () => unawaited(flush()));
    }
  }

  /// Writes [c] now (publishing calls this right after clearing the
  /// composer) and completes when the file is written.
  Future<void> keep(ComposerState c) {
    if (!restored) return _lastWrite;
    _unsaved = c;
    return flush();
  }

  /// Writes a change still waiting for its moment now. Completes when the
  /// latest write is done.
  Future<void> flush() {
    _pending?.cancel();
    _pending = null;
    final c = _unsaved;
    _unsaved = null;
    if (c != null) _lastWrite = _write(c);
    return _lastWrite;
  }

  Future<void> _write(ComposerState c) async {
    try {
      await _storage.writeJson(kComposerDraftFile, isComposerBlank(c) ? const <String, dynamic>{} : composerDraftToJson(c));
    } on Object catch (e) {
      debugPrint('Could not keep the post being written: $e');
    }
  }
}

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
      // By the composer's own part numbers, which count empty parts too.
      if (c.mediaParts.isNotEmpty) 'mediaParts': c.mediaParts,
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
    mediaParts: j['mediaParts'] is Map
        ? {
            for (final e in (j['mediaParts'] as Map).entries)
              if (e.value is int) '${e.key}': e.value as int,
          }
        : p.mediaParts,
  );
}

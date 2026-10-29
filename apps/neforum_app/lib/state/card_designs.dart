import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show EdgeInsets, Size;
import 'package:neforum_core/neforum_core.dart' hide Visibility;

import '../media/caption_fonts.dart';
import '../media/card_design.dart';
import '../media/card_renderer.dart';
import '../media/photo_pixels.dart';
import '../media/render_parameters.dart';
import '../media/text_card_background.dart';
import '../media/waveform.dart';
import '../platform/pcm_file.dart';
import '../platform/storage.dart';

// The card designer's place in posts and saved files (1.3.1): which design a
// post's text cards and audio cards use, and the one function per kind that
// draws a card from its design, used alike by the saved card, the composer's
// previews and the editor.

/// `PostOverrides.extra` key, on every target of a post whose text cards use
/// a design of its own: the design's JSON, or an empty map for the classic
/// card. Absent: the Settings default.
const String kTextCardDesignKey = 'textCardDesign';

/// `PostOverrides.extra` key, like [kTextCardDesignKey], for the picture of a
/// sound file's video.
const String kAudioCardDesignKey = 'audioCardDesign';

/// [post] with the composer's card designs written into its targets, so a
/// scheduled or background run draws the cards the way the post was saved.
/// Null leaves a kind to the Settings default.
Post withCardDesigns(Post post, {Map<String, dynamic>? text, Map<String, dynamic>? audio}) => post.copyWith(targets: [
      for (final t in post.targets)
        t.copyWith(
          overrides: t.overrides.copyWith(extra: {
            ...withoutCardDesigns(t.overrides).extra,
            kTextCardDesignKey: ?text,
            kAudioCardDesignKey: ?audio,
          }),
        ),
    ]);

/// [o] without the designs [withCardDesigns] writes.
PostOverrides withoutCardDesigns(PostOverrides o) => o.extra.containsKey(kTextCardDesignKey) || o.extra.containsKey(kAudioCardDesignKey)
    ? o.copyWith(extra: {...o.extra}..remove(kTextCardDesignKey)..remove(kAudioCardDesignKey))
    : o;

Map<String, dynamic>? _designOfPost(Post post, String key) {
  for (final t in post.targets) {
    final raw = t.overrides.extra[key];
    if (raw is Map) return Map<String, dynamic>.from(raw);
  }
  return null;
}

/// The design [post] chose for its text cards: the design's JSON, an empty
/// map for the classic card, null for the Settings default.
Map<String, dynamic>? textCardDesignChoiceOfPost(Post post) => _designOfPost(post, kTextCardDesignKey);

/// The design [post] chose for its sound file's picture, like
/// [textCardDesignChoiceOfPost].
Map<String, dynamic>? audioCardDesignChoiceOfPost(Post post) => _designOfPost(post, kAudioCardDesignKey);

/// The design a choice stands for: [choice] (empty: the classic card, so
/// null), or the Settings default [fallback] when [choice] is null.
CardDesign? effectiveCardDesign(Map<String, dynamic>? choice, Map<String, dynamic> fallback) =>
    CardDesign.tryParse(choice ?? fallback);

/// Loads every installed or imported font [design] uses ([usage] names the
/// card in the notice when one is missing); true when they are all here.
Future<bool> prepareCardDesignFonts(AppStorage storage, CardDesign design, {required String usage}) async {
  var all = true;
  for (final f in design.customFonts) {
    if (!await prepareCaptionFontForRender(storage, f, usage: usage)) all = false;
  }
  return all;
}

/// The seed of a decorative waveform for [identity].
int waveformSeed(String identity) => int.parse(stableHash(identity), radix: 16);

/// Draws a text card from [design] as a JPEG: the words, the @handle
/// ([byline], null to leave it out) and the signature (left out when not
/// [signed]); the background photo and its adjustments from [backdrop]
/// (decoded for a saved card), which also fills the cover layer. The saved
/// card, the composer's previews and the editor all draw through here.
Future<Uint8List> renderDesignedTextCard(AppStorage storage,
    {required CardDesign design,
    required String platformId,
    required Size size,
    EdgeInsets safe = EdgeInsets.zero,
    required String text,
    String? byline,
    bool signed = true,
    TextCardBackdrop? backdrop}) async {
  await prepareCardDesignFonts(storage, design, usage: 'the text card');
  final photo = backdrop?.pixels;
  return renderCardDesign(CardRenderInput(
    design: design,
    size: size,
    safe: safe,
    platformId: platformId,
    texts: {
      CardBlockRole.postText: text,
      CardBlockRole.handle: byline ?? '',
      if (!signed) CardBlockRole.signature: '',
    },
    photo: photo,
    photoBackground: backdrop?.background,
    cover: photo,
    waveform: design.waveform.visible ? decorativeWaveform(waveformSeed(text)) : null,
  ));
}

/// The words of an audio card's blocks from the track's effective [tags]:
/// the title ([fallbackTitle] when the tags have none), the artist (or album
/// artist) and "Album · 2024".
Map<CardBlockRole, String> audioCardTexts(AudioTags tags, {required String fallbackTitle, String? handle}) {
  final title = (tags.title ?? '').trim();
  final artist = (tags.artist ?? tags.albumArtist ?? '').trim();
  final album = [if ((tags.album ?? '').trim().isNotEmpty) tags.album!.trim(), if (tags.year != null) '${tags.year}'].join(' · ');
  return {
    CardBlockRole.title: title.isEmpty ? fallbackTitle : title,
    CardBlockRole.artist: artist,
    CardBlockRole.albumYear: album,
    CardBlockRole.handle: handle ?? '',
  };
}

/// Draws an audio card from [design] as a PNG (the still picture of a sound
/// file's video) or a JPEG: [texts] from [audioCardTexts], [cover] (the
/// cover art, or the post's photo) as the photo fill and the cover layer,
/// [waveform] for the waveform layer.
Future<Uint8List> renderDesignedAudioCard(AppStorage storage,
    {required CardDesign design,
    required String platformId,
    required Size size,
    EdgeInsets safe = EdgeInsets.zero,
    required Map<CardBlockRole, String> texts,
    PhotoPixels? cover,
    WaveformLevels? waveform,
    bool png = true}) async {
  await prepareCardDesignFonts(storage, design, usage: 'the audio card');
  return renderCardDesign(
    CardRenderInput(
      design: design,
      size: size,
      safe: safe,
      platformId: platformId,
      texts: texts,
      photo: cover,
      cover: cover,
      waveform: waveform?.levels,
    ),
    png: png,
  );
}

/// Longest side cover art is decoded at for a card.
const int kCoverMaxSide = 1600;

/// The picture at [path] in NEFORUM's media folder, decoded for a card; null
/// when it cannot be read.
Future<PhotoPixels?> decodeCardPicture(AppStorage storage, String path) async {
  try {
    return await decodePhotoPixels(await storage.readMedia(path), maxSide: kCoverMaxSide);
  } on Object catch (e) {
    debugPrint('Could not read the picture for the card: $e');
    return null;
  }
}

final Map<String, Future<WaveformLevels>> _waveforms = {};

/// The levels of [sound] for an audio card: measured from WAV and AIFF
/// files, a decorative shape seeded from the file otherwise
/// ([WaveformLevels.measured] says which). Worked out once per file each run,
/// off the UI isolate.
Future<WaveformLevels> waveformOfSound(AppStorage storage, MediaAttachment sound) =>
    _waveforms[sound.path] ??= _measure(storage, sound).catchError((Object e) {
      debugPrint('Could not read the levels of ${sound.fileName ?? sound.id}: $e');
      return _decorative(sound);
    });

WaveformLevels _decorative(MediaAttachment sound) =>
    WaveformLevels(decorativeWaveform(waveformSeed('${sound.sizeBytes}|${sound.fileName}|${sound.durationMs}')), measured: false);

/// Whether NEFORUM measures the levels of a file of [mimeType] itself.
bool measuresWaveformOf(String mimeType) {
  final m = mimeType.toLowerCase();
  return m.contains('wav') || m.contains('aiff') || m.contains('aif');
}

Future<WaveformLevels> _measure(AppStorage storage, MediaAttachment sound) async {
  if (!measuresWaveformOf(sound.mimeType)) return _decorative(sound);
  final List<double>? levels;
  if (storage.dataDir != null) {
    // A file on disk: the other isolate reads its headers and a few blocks
    // of frames itself, so the file is neither read whole nor copied.
    levels = await compute(_measureFileJob, sound.path);
  } else {
    // No files (the web preview, storage in memory): read whole, when small.
    if (sound.sizeBytes > kWaveformMaxBytes) return _decorative(sound);
    levels = await compute(_measureJob, await storage.readMedia(sound.path));
  }
  return levels == null ? _decorative(sound) : WaveformLevels(levels, measured: true);
}

/// [measurePcmFile] for `compute`: top level, plain data in and out.
List<double>? _measureFileJob(String path) => measurePcmFile(path);

/// [measurePcmWaveform] for `compute`: top level, plain data in and out.
List<double>? _measureJob(Uint8List bytes) => measurePcmWaveform(bytes);

/// Forgets the levels worked out so far, for tests.
@visibleForTesting
void debugResetWaveforms() => _waveforms.clear();

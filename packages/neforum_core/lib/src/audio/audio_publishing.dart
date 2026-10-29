import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../model/audio.dart';
import '../model/audio_tags.dart';
import '../model/media.dart';
import '../model/post.dart';
import 'audio_thumbnail_stub.dart' if (dart.library.io) 'audio_thumbnail_io.dart' as off_thread;

/// The tags a post's sound files go out with.
extension PostAudioTags on Post {
  /// The tags [m] goes out with: those of the user's sound file it is (or
  /// that NEFORUM made it from: the Standard copy, the still-picture video),
  /// under the user's edits ([audioDetails]). Null when [m] is not a sound
  /// file nor made from one, or when nothing is known about the track.
  AudioTags? effectiveAudioTagsOf(MediaAttachment m) {
    final from = m.derivedFrom;
    final source = from == null ? m : media.where((x) => x.id == from).firstOrNull;
    if (source == null || !source.isAudio) return null;
    final tags = (source.audioTags ?? AudioTags.none).overriddenBy(audioDetails);
    return tags.isEmpty ? null : tags;
  }

  /// [media] with each sound file (and each file made from one) carrying its
  /// [effectiveAudioTagsOf] in [MediaAttachment.audioTags], so adapters read
  /// the track's details from the file they post.
  List<MediaAttachment> withEffectiveAudioTags(List<MediaAttachment> items) => [
        for (final m in items)
          if (effectiveAudioTagsOf(m) case final tags? when tags != m.audioTags)
            m.copyWith(audioTags: tags)
          else if (m.isAudio && m.audioTags != null && effectiveAudioTagsOf(m) == null)
            m.copyWith(clearAudioTags: true)
          else
            m,
      ];
}

/// Readers for the track details adapters send along with a sound file.
extension AudioTagsOfAttachment on MediaAttachment {
  /// "Artist – Title" for the file's alt text or description; null without
  /// either.
  String? get audioCaption => audioTags?.artistAndTitle;

  /// The cover picture as an attachment [AdapterContext.readMedia] can read;
  /// null without one.
  MediaAttachment? get audioCover {
    final t = audioTags;
    final path = t?.coverPath;
    if (t == null || path == null || path.isEmpty) return null;
    final mime = t.coverMimeType ?? 'image/jpeg';
    return MediaAttachment(id: '$id-cover', path: path, mimeType: mime, sizeBytes: 0, fileName: 'cover.${mime == 'image/png' ? 'png' : 'jpg'}');
  }

  /// "Artist - Title.mp3" for a sound file whose track details say who and
  /// what it is; null otherwise. Characters file systems refuse are left out.
  String? get audioTaggedFileName {
    final t = audioTags;
    if (t == null || !isAudio) return null;
    final a = t.artist?.trim() ?? '', title = t.title?.trim() ?? '';
    final base = a.isEmpty ? title : (title.isEmpty ? a : '$a - $title');
    final safe = safeAudioFileStem(base);
    if (safe.isEmpty) return null;
    final audio = canonicalAudioMimeType(mimeType);
    return '$safe.${audio == null ? 'bin' : audioExtensionFor(audio)}';
  }
}

/// [s] without the characters Windows, macOS and Linux refuse in file names
/// (`\ / : * ? " < > |` and control characters), spaces collapsed, no dots
/// or spaces at the ends, at most 120 characters.
String safeAudioFileStem(String s) {
  var out = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  out = out.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (out.length > 120) out = out.substring(0, 120).trimRight();
  return out;
}

/// [cover] as a JPEG no wider or taller than [maxSide] and under [maxBytes]
/// (Telegram's thumbnail rules: 320 px, 200 kB), made in another isolate
/// where there is one; null when the picture cannot be read.
Future<Uint8List?> audioThumbnailJpeg(Uint8List cover, {int maxSide = 320, int maxBytes = 200 * 1024}) =>
    off_thread.runAudioThumbnail(cover, maxSide, maxBytes);

/// [audioThumbnailJpeg]'s work, synchronously.
Uint8List? audioThumbnailJpegSync(Uint8List cover, int maxSide, int maxBytes) {
  try {
    final decoded = img.decodeImage(cover);
    if (decoded == null || decoded.width == 0 || decoded.height == 0) return null;
    var image = img.bakeOrientation(decoded);
    if (image.width > maxSide || image.height > maxSide) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxSide, interpolation: img.Interpolation.average)
          : img.copyResize(image, height: maxSide, interpolation: img.Interpolation.average);
    }
    final rgb = image.numChannels == 3 ? image : image.convert(numChannels: 3);
    for (var quality = 88; quality >= 40; quality -= 12) {
      final jpeg = img.encodeJpg(rgb, quality: quality);
      if (jpeg.length < maxBytes) return jpeg;
    }
    return null;
  } on Object {
    return null;
  }
}

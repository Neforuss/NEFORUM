import 'media.dart';

/// How a post's sound file reaches the networks that take sound
/// ([Post.audioQuality]).
enum AudioQuality {
  /// One MP3 for every network: an MP3 goes as it is, anything else is
  /// converted once (to M4A AAC where the device has no MP3 encoder).
  standard,

  /// The original file, unchanged, wherever a network takes its type. Only
  /// offered for lossless files (WAV, AIFF, FLAC, Apple Lossless).
  lossless,
}

/// The sound file types NEFORUM accepts, by their canonical MIME type
/// ([canonicalAudioMimeType]).
abstract final class AudioMimeTypes {
  static const String mp3 = 'audio/mpeg';

  /// M4A: AAC or Apple Lossless (ALAC) in an MPEG-4 container.
  static const String m4a = 'audio/mp4';
  static const String wav = 'audio/wav';
  static const String flac = 'audio/flac';
  static const String aiff = 'audio/aiff';

  /// Ogg Vorbis and Ogg Opus.
  static const String ogg = 'audio/ogg';

  static const Set<String> all = {mp3, m4a, wav, flac, aiff, ogg};

  /// Containers that only ever hold lossless sound.
  static const Set<String> losslessContainers = {wav, flac, aiff};
}

/// Codec names in [MediaAttachment.audioCodec].
abstract final class AudioCodecs {
  static const String mp3 = 'mp3';
  static const String aac = 'aac';
  static const String alac = 'alac';

  /// Uncompressed samples (WAV, AIFF), integer or floating point.
  static const String pcm = 'pcm';
  static const String flac = 'flac';
  static const String vorbis = 'vorbis';
  static const String opus = 'opus';

  static const Set<String> lossless = {alac, pcm, flac};
}

/// The canonical MIME type for a sound file type, folding the aliases
/// browsers and file pickers report (`audio/x-wav`, `audio/x-m4a`...).
/// Null when [mimeType] is not a sound type NEFORUM accepts.
String? canonicalAudioMimeType(String? mimeType) {
  final m = mimeType?.split(';').first.trim().toLowerCase();
  return switch (m) {
    'audio/mpeg' || 'audio/mp3' || 'audio/mpeg3' || 'audio/x-mpeg' || 'audio/x-mp3' => AudioMimeTypes.mp3,
    'audio/mp4' || 'audio/x-m4a' || 'audio/m4a' || 'audio/aac' || 'audio/x-aac' || 'audio/mp4a-latm' => AudioMimeTypes.m4a,
    'audio/wav' || 'audio/x-wav' || 'audio/wave' || 'audio/vnd.wave' || 'audio/x-pn-wav' => AudioMimeTypes.wav,
    'audio/flac' || 'audio/x-flac' => AudioMimeTypes.flac,
    'audio/aiff' || 'audio/x-aiff' || 'audio/aif' || 'audio/x-aifc' => AudioMimeTypes.aiff,
    'audio/ogg' || 'audio/opus' || 'audio/vorbis' || 'audio/x-ogg' => AudioMimeTypes.ogg,
    _ => null,
  };
}

/// The usual file extension for a canonical sound MIME type.
String audioExtensionFor(String mimeType) => switch (mimeType) {
      AudioMimeTypes.mp3 => 'mp3',
      AudioMimeTypes.m4a => 'm4a',
      AudioMimeTypes.wav => 'wav',
      AudioMimeTypes.flac => 'flac',
      AudioMimeTypes.aiff => 'aiff',
      AudioMimeTypes.ogg => 'ogg',
      _ => 'bin',
    };

/// A short name for the file type, for messages: "MP3", "FLAC", "Apple
/// Lossless".
String audioFormatLabel(MediaAttachment m) {
  if (m.audioCodec == AudioCodecs.alac) return 'Apple Lossless';
  if (m.audioCodec == AudioCodecs.opus) return 'Opus';
  return switch (m.mimeType) {
    AudioMimeTypes.mp3 => 'MP3',
    AudioMimeTypes.m4a => 'M4A',
    AudioMimeTypes.wav => 'WAV',
    AudioMimeTypes.flac => 'FLAC',
    AudioMimeTypes.aiff => 'AIFF',
    AudioMimeTypes.ogg => 'Ogg',
    _ => m.mimeType,
  };
}

extension AudioAttachment on MediaAttachment {
  /// Sound kept sample for sample: WAV, AIFF and FLAC files and Apple
  /// Lossless in M4A. A WAV or AIFF file holding compressed sound (rare) is
  /// not, when its codec is known.
  bool get isLosslessAudio {
    if (!isAudio) return false;
    final codec = audioCodec;
    if (codec != null) return AudioCodecs.lossless.contains(codec);
    return AudioMimeTypes.losslessContainers.contains(mimeType);
  }

  /// An MP3 file: Standard quality sends it as it is.
  bool get isMp3 => isAudio && mimeType == AudioMimeTypes.mp3;
}

extension MediaNoun on MediaAttachment {
  /// What the file is, for progress messages: "image", "video" or "sound
  /// file".
  String get noun => switch (kind) {
        MediaKind.video => 'video',
        MediaKind.audio => 'sound file',
        MediaKind.image || MediaKind.gif => 'image',
      };
}

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:neforum_core/neforum_core.dart' show AudioCodecs, AudioMimeTypes, canonicalAudioMimeType;

/// What [probeAudio] read from a sound file's own bytes.
class AudioProbe {
  const AudioProbe({required this.mimeType, this.codec, this.durationMs, this.sampleRate, this.channels});

  /// Canonical type ([AudioMimeTypes]).
  final String mimeType;

  /// [AudioCodecs] name, or null when the container does not say.
  final String? codec;
  final int? durationMs;
  final int? sampleRate;
  final int? channels;

  @override
  String toString() => 'AudioProbe($mimeType, $codec, ${durationMs}ms, ${sampleRate}Hz, ${channels}ch)';
}

/// Reads a sound file's type, codec and length from its headers, cheaply: a
/// WAV `fmt `/`data` chunk, AIFF `COMM`, FLAC STREAMINFO, an MP3's first frame
/// and its Xing/Info or VBRI header (else its bitrate), an MP4's `mvhd` and
/// sample description, or an Ogg stream's first and last pages. Nothing is
/// decoded. Null when [bytes] are not a sound file NEFORUM takes; the length
/// stays null where the headers do not give it.
///
/// [fileName] and [mimeHint] settle files that only their name tells apart
/// (an MP3 without an ID3 tag, an M4A whose brand reads as video).
AudioProbe? probeAudio(Uint8List bytes, {String? fileName, String? mimeHint}) {
  final b = _Bytes(bytes);
  if (b.ascii(0, 4) == 'RIFF' && b.ascii(8, 4) == 'WAVE') return _wav(b);
  if (b.ascii(0, 4) == 'FORM' && (b.ascii(8, 4) == 'AIFF' || b.ascii(8, 4) == 'AIFC')) return _aiff(b);
  final id3 = _id3Length(b);
  if (b.ascii(id3, 4) == 'fLaC') return _flac(b, id3 + 4);
  if (b.ascii(0, 4) == 'OggS') return _ogg(b);
  // An MP4 with a video track is a video, not a sound file.
  if (b.ascii(4, 4) == 'ftyp') return _mp4(b);
  final ext = _extension(fileName);
  final hinted = canonicalAudioMimeType(mimeHint);
  if (id3 > 0 || ext == 'mp3' || hinted == AudioMimeTypes.mp3 || _frameAt(b, 0) != null) {
    return _mp3(b, id3);
  }
  return null;
}

String _extension(String? name) {
  final n = (name ?? '').toLowerCase();
  final dot = n.lastIndexOf('.');
  return dot < 0 ? '' : n.substring(dot + 1);
}

// --------------------------------------------------------------------- WAV

AudioProbe _wav(_Bytes b) {
  int? format, channels, rate, byteRate;
  int? dataSize;
  var at = 12;
  while (at + 8 <= b.length) {
    final id = b.ascii(at, 4);
    final size = b.u32le(at + 4);
    final body = at + 8;
    if (id == 'fmt ' && size >= 16) {
      format = b.u16le(body);
      channels = b.u16le(body + 2);
      rate = b.u32le(body + 4);
      byteRate = b.u32le(body + 8);
      // WAVE_FORMAT_EXTENSIBLE: the real format leads the sub-format GUID.
      if (format == 0xFFFE && size >= 40) format = b.u16le(body + 24);
    } else if (id == 'data') {
      // A file still being written (or streamed) says 0 or more than it has.
      dataSize = size == 0 || body + size > b.length ? b.length - body : size;
      break;
    }
    at = body + size + (size & 1);
  }
  final codec = switch (format) {
    1 || 3 => AudioCodecs.pcm, // integer or IEEE float samples
    0x55 => AudioCodecs.mp3,
    0xF1AC => AudioCodecs.flac,
    null => null,
    _ => 'other',
  };
  final ms = byteRate != null && byteRate > 0 && dataSize != null ? (dataSize * 1000 / byteRate).round() : null;
  return AudioProbe(mimeType: AudioMimeTypes.wav, codec: codec, durationMs: ms, sampleRate: rate, channels: channels);
}

// -------------------------------------------------------------------- AIFF

AudioProbe _aiff(_Bytes b) {
  final aifc = b.ascii(8, 4) == 'AIFC';
  var at = 12;
  while (at + 8 <= b.length) {
    final id = b.ascii(at, 4);
    final size = b.u32be(at + 4);
    final body = at + 8;
    if (id == 'COMM' && size >= 18 && body + 18 <= b.length) {
      final channels = b.u16be(body);
      final frames = b.u32be(body + 2);
      final rate = _extended80(b, body + 8);
      var codec = AudioCodecs.pcm;
      if (aifc && size >= 22) {
        final type = b.ascii(body + 18, 4);
        // Uncompressed AIFC types; anything else (ima4, ulaw...) is lossy.
        if (!const {'NONE', 'sowt', 'twos', 'raw ', 'in24', 'in32', 'fl32', 'fl64', 'FL32', 'FL64'}.contains(type)) codec = 'other';
      }
      final ms = rate != null && rate > 0 ? (frames * 1000 / rate).round() : null;
      return AudioProbe(mimeType: AudioMimeTypes.aiff, codec: codec, durationMs: ms, sampleRate: rate?.round(), channels: channels);
    }
    at = body + size + (size & 1);
  }
  return const AudioProbe(mimeType: AudioMimeTypes.aiff, codec: AudioCodecs.pcm);
}

/// An IEEE 754 80-bit extended float (AIFF's sample rate).
double? _extended80(_Bytes b, int at) {
  if (at + 10 > b.length) return null;
  final exponent = b.u16be(at) & 0x7FFF;
  var mantissa = 0.0;
  for (var i = 0; i < 8; i++) {
    mantissa = mantissa * 256 + b[at + 2 + i];
  }
  if (exponent == 0 && mantissa == 0) return 0;
  return mantissa * math.pow(2, exponent - 16383 - 63);
}

// -------------------------------------------------------------------- FLAC

AudioProbe _flac(_Bytes b, int at) {
  // The first metadata block is always STREAMINFO (34 bytes).
  final type = at < b.length ? b[at] & 0x7F : -1;
  if (type != 0 || at + 4 + 18 > b.length) return const AudioProbe(mimeType: AudioMimeTypes.flac, codec: AudioCodecs.flac);
  final s = at + 4;
  final rate = (b[s + 10] << 12) | (b[s + 11] << 4) | (b[s + 12] >> 4);
  final channels = ((b[s + 12] >> 1) & 0x07) + 1;
  final samples = ((b[s + 13] & 0x0F) * 0x100000000) + b.u32be(s + 14);
  final ms = rate > 0 && samples > 0 ? (samples * 1000 / rate).round() : null;
  return AudioProbe(mimeType: AudioMimeTypes.flac, codec: AudioCodecs.flac, durationMs: ms, sampleRate: rate, channels: channels);
}

// --------------------------------------------------------------------- MP3

/// Bytes of an ID3v2 tag at the start (header, body and footer), else 0.
int _id3Length(_Bytes b) {
  if (b.ascii(0, 3) != 'ID3' || b.length < 10) return 0;
  final size = (b[6] & 0x7F) << 21 | (b[7] & 0x7F) << 14 | (b[8] & 0x7F) << 7 | (b[9] & 0x7F);
  final footer = (b[5] & 0x10) != 0 ? 10 : 0;
  return 10 + size + footer;
}

class _Frame {
  const _Frame({required this.version, required this.layer, required this.bitrate, required this.sampleRate, required this.mono, required this.length});

  /// 1 (MPEG-1), 2 (MPEG-2) or 25 (MPEG-2.5).
  final int version;
  final int layer;

  /// Bits per second.
  final int bitrate;
  final int sampleRate;
  final bool mono;
  final int length;

  int get samplesPerFrame => layer == 1 ? 384 : (layer == 3 && version != 1 ? 576 : 1152);
}

const _bitratesV1 = [
  [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448], // layer I
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384], // layer II
  [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320], // layer III
];
const _bitratesV2 = [
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256], // layer I
  [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160], // layers II and III
];

/// The MPEG audio frame header at [at], or null when there is none.
_Frame? _frameAt(_Bytes b, int at) {
  if (at + 4 > b.length || b[at] != 0xFF || (b[at + 1] & 0xE0) != 0xE0) return null;
  final versionBits = (b[at + 1] >> 3) & 0x03;
  final layerBits = (b[at + 1] >> 1) & 0x03;
  final bitrateIndex = b[at + 2] >> 4;
  final rateIndex = (b[at + 2] >> 2) & 0x03;
  if (versionBits == 1 || layerBits == 0 || bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) return null;
  final version = switch (versionBits) { 3 => 1, 2 => 2, _ => 25 };
  final layer = 4 - layerBits;
  final kbps = version == 1 ? _bitratesV1[layer - 1][bitrateIndex] : _bitratesV2[layer == 1 ? 0 : 1][bitrateIndex];
  final rate = const [44100, 48000, 32000][rateIndex] ~/ (version == 1 ? 1 : (version == 2 ? 2 : 4));
  final padding = (b[at + 2] >> 1) & 0x01;
  final mono = (b[at + 3] >> 6) == 3;
  final length = layer == 1 ? (12 * kbps * 1000 ~/ rate + padding) * 4 : ((layer == 3 && version != 1 ? 72 : 144) * kbps * 1000 ~/ rate + padding);
  return _Frame(version: version, layer: layer, bitrate: kbps * 1000, sampleRate: rate, mono: mono, length: length);
}

AudioProbe? _mp3(_Bytes b, int start) {
  // The first frame: two headers in a row, so stray 0xFF bytes in junk
  // before it are not taken for one.
  _Frame? frame;
  var at = start;
  final limit = start + 64 * 1024 < b.length ? start + 64 * 1024 : b.length;
  for (; at + 4 <= limit; at++) {
    final f = _frameAt(b, at);
    if (f == null || f.length <= 0) continue;
    if (at + f.length + 4 > b.length || _frameAt(b, at + f.length) != null) {
      frame = f;
      break;
    }
  }
  final f = frame;
  if (f == null) return null;
  AudioProbe probe(int? ms) =>
      AudioProbe(mimeType: AudioMimeTypes.mp3, codec: AudioCodecs.mp3, durationMs: ms, sampleRate: f.sampleRate, channels: f.mono ? 1 : 2);
  // Xing/Info (VBR and LAME CBR): after the side information.
  final side = f.version == 1 ? (f.mono ? 17 : 32) : (f.mono ? 9 : 17);
  final xing = at + 4 + side;
  final tag = b.ascii(xing, 4);
  if ((tag == 'Xing' || tag == 'Info') && (b.u32be(xing + 4) & 0x01) != 0) {
    final frames = b.u32be(xing + 8);
    if (frames > 0) return probe((frames * f.samplesPerFrame * 1000 / f.sampleRate).round());
  }
  // VBRI (Fraunhofer): 32 bytes after the header.
  if (b.ascii(at + 36, 4) == 'VBRI') {
    final frames = b.u32be(at + 36 + 14);
    if (frames > 0) return probe((frames * f.samplesPerFrame * 1000 / f.sampleRate).round());
  }
  // Constant bitrate: the audio bytes over the bitrate, without an ID3v1 tag.
  var audioBytes = b.length - at;
  if (b.length >= 128 && b.ascii(b.length - 128, 3) == 'TAG') audioBytes -= 128;
  return probe((audioBytes * 8 * 1000 / f.bitrate).round());
}

// --------------------------------------------------------------------- MP4

AudioProbe? _mp4(_Bytes b) {
  final moov = _box(b, 0, b.length, 'moov');
  if (moov == null) return const AudioProbe(mimeType: AudioMimeTypes.m4a);
  int? ms;
  final mvhd = _box(b, moov.$1, moov.$2, 'mvhd');
  if (mvhd != null) {
    final v = b[mvhd.$1];
    final timescale = v == 1 ? b.u32be(mvhd.$1 + 20) : b.u32be(mvhd.$1 + 12);
    final duration = v == 1 ? b.u32be(mvhd.$1 + 24) * 0x100000000 + b.u32be(mvhd.$1 + 28) : b.u32be(mvhd.$1 + 16);
    if (timescale > 0) ms = (duration * 1000 / timescale).round();
  }
  String? codec;
  int? rate, channels;
  var hasVideo = false;
  var at = moov.$1;
  while (true) {
    final trak = _box(b, at, moov.$2, 'trak');
    if (trak == null) break;
    at = trak.$2;
    final mdia = _box(b, trak.$1, trak.$2, 'mdia');
    if (mdia == null) continue;
    final hdlr = _box(b, mdia.$1, mdia.$2, 'hdlr');
    final handler = hdlr == null ? '' : b.ascii(hdlr.$1 + 8, 4);
    if (handler == 'vide') hasVideo = true;
    if (handler != 'soun' || codec != null) continue;
    final minf = _box(b, mdia.$1, mdia.$2, 'minf');
    final stbl = minf == null ? null : _box(b, minf.$1, minf.$2, 'stbl');
    final stsd = stbl == null ? null : _box(b, stbl.$1, stbl.$2, 'stsd');
    if (stsd == null) continue;
    // Full box header, entry count, then the first sample entry.
    final entry = stsd.$1 + 8;
    final type = b.ascii(entry + 4, 4);
    codec = switch (type) {
      'mp4a' => AudioCodecs.aac,
      'alac' => AudioCodecs.alac,
      'fLaC' => AudioCodecs.flac,
      'Opus' => AudioCodecs.opus,
      '.mp3' => AudioCodecs.mp3,
      _ => 'other',
    };
    // AudioSampleEntry: channel count at +24, sample rate (16.16) at +32.
    if (entry + 36 <= b.length) {
      channels = b.u16be(entry + 24);
      rate = b.u16be(entry + 32);
    }
  }
  if (hasVideo) return null;
  return AudioProbe(mimeType: AudioMimeTypes.m4a, codec: codec, durationMs: ms, sampleRate: rate, channels: channels);
}

/// The body (start, end) of the first [type] box between [from] and [to].
(int, int)? _box(_Bytes b, int from, int to, String type) {
  var at = from;
  while (at + 8 <= to) {
    var size = b.u32be(at);
    var header = 8;
    if (size == 1 && at + 16 <= to) {
      size = b.u32be(at + 8) * 0x100000000 + b.u32be(at + 12);
      header = 16;
    } else if (size == 0) {
      size = to - at;
    }
    if (size < header) return null;
    if (b.ascii(at + 4, 4) == type) return (at + header, at + size > to ? to : at + size);
    at += size;
  }
  return null;
}

// --------------------------------------------------------------------- Ogg

AudioProbe _ogg(_Bytes b) {
  // The first page holds the codec's identification header.
  final segments = b.length > 26 ? b[26] : 0;
  final packet = 27 + segments;
  String? codec;
  int? rate, channels;
  var preSkip = 0;
  if (b.ascii(packet, 8) == 'OpusHead') {
    codec = AudioCodecs.opus;
    channels = b[packet + 9];
    preSkip = b.u16le(packet + 10);
    rate = 48000; // Opus granule positions always count 48 kHz samples.
  } else if (b.length > packet + 16 && b[packet] == 1 && b.ascii(packet + 1, 6) == 'vorbis') {
    codec = AudioCodecs.vorbis;
    channels = b[packet + 11];
    rate = b.u32le(packet + 12);
  } else if (b.ascii(packet, 5) == '\x7FFLAC') {
    codec = AudioCodecs.flac;
    final info = packet + 13; // "\x7FFLAC", version, header count, "fLaC", block header
    if (info + 18 <= b.length) {
      rate = (b[info + 10] << 12) | (b[info + 11] << 4) | (b[info + 12] >> 4);
      channels = ((b[info + 12] >> 1) & 0x07) + 1;
    }
  }
  // The last page's granule position is the stream's length in samples.
  int? ms;
  final from = b.length - 65307 > 0 ? b.length - 65307 : 0;
  for (var at = b.length - 27; at >= from; at--) {
    if (b[at] != 0x4F || b.ascii(at, 4) != 'OggS') continue;
    final granule = b.u32le(at + 6) + b.u32le(at + 10) * 0x100000000;
    if (rate != null && rate > 0 && granule > preSkip) ms = ((granule - preSkip) * 1000 / rate).round();
    break;
  }
  return AudioProbe(mimeType: AudioMimeTypes.ogg, codec: codec, durationMs: ms, sampleRate: rate, channels: channels);
}

// ------------------------------------------------------------------- bytes

/// Bounds-checked reads: past the end reads as 0, so a cut-off file gives
/// no length instead of an exception.
class _Bytes {
  const _Bytes(this.data);
  final Uint8List data;

  int get length => data.length;
  int operator [](int i) => i >= 0 && i < data.length ? data[i] : 0;
  int u16le(int at) => this[at] | this[at + 1] << 8;
  int u16be(int at) => this[at] << 8 | this[at + 1];
  // Multiplied, not shifted, so the top byte never turns the value negative on the web.
  int u32le(int at) => u16le(at) + u16le(at + 2) * 0x10000;
  int u32be(int at) => u16be(at) * 0x10000 + u16be(at + 2);
  String ascii(int at, int count) => String.fromCharCodes([for (var i = 0; i < count; i++) this[at + i]]);
}

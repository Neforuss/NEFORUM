import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Levels of a sound for an audio card's waveform layer: [levels] (0 to 1,
/// the loudest bin 1) and whether they were [measured] from the samples.
///
/// NEFORUM reads uncompressed PCM itself: WAV (8, 16, 24 and 32-bit integer
/// and 32 or 64-bit float, WAVE_FORMAT_EXTENSIBLE included) and AIFF/AIFC
/// (big-endian, and little-endian "sowt"). Compressed sound (MP3, AAC, FLAC,
/// Opus, Vorbis) would need a decoder NEFORUM does not ship; its waveform is a
/// [decorativeWaveform] seeded from the file, so the same file always draws
/// the same shape, and the editor says it is decorative.
@immutable
class WaveformLevels {
  const WaveformLevels(this.levels, {required this.measured});
  final List<double> levels;
  final bool measured;
}

/// How many bins a waveform is measured into; the card resamples them to its
/// bar count.
const int kWaveformBins = 256;

/// Sound files read whole for their levels (where there is no file to read
/// in parts: the web preview, storage in memory) are at most this big; a
/// decorative waveform is drawn for larger ones. Files on disk are read in
/// parts ([measurePcmSource]) whatever their size.
const int kWaveformMaxBytes = 32 * 1024 * 1024;

/// Random access to the bytes of a sound file for [measurePcmSource]: a file
/// read in parts, or bytes in memory ([PcmBytes]).
abstract interface class PcmSource {
  /// The file's length in bytes.
  int get length;

  /// Up to [count] bytes from [offset]; fewer at the end of the file, none
  /// past it.
  Uint8List read(int offset, int count);
}

/// A [PcmSource] over bytes in memory.
class PcmBytes implements PcmSource {
  PcmBytes(this.bytes);
  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Uint8List read(int offset, int count) {
    if (offset < 0 || offset >= bytes.length || count <= 0) return Uint8List(0);
    return Uint8List.sublistView(bytes, offset, math.min(bytes.length, offset + count));
  }
}

/// How many blocks of frames [measurePcmSource] reads from each bin that is
/// too long to read whole: 256 bins make at most 4,096 reads per file.
const int _blocksPerBin = 16;

/// The most bytes in one block (and at most 256 frames): with
/// [_blocksPerBin], at most 8 MB of a file is read, however long it is.
const int _blockBytes = 2048;

/// The levels of the PCM sound in [bytes] (a WAV or AIFF file), as the RMS of
/// [bins] equal stretches of it over every channel, scaled so the loudest is
/// 1; null when [bytes] is not PCM NEFORUM can read. Top level, for
/// `compute`.
List<double>? measurePcmWaveform(Uint8List bytes, {int bins = kWaveformBins}) => measurePcmSource(PcmBytes(bytes), bins: bins);

/// [measurePcmWaveform] on a file read in parts: its chunk headers, then a
/// few evenly spread blocks of frames from each bin (each short bin whole),
/// never the whole file.
List<double>? measurePcmSource(PcmSource source, {int bins = kWaveformBins}) {
  final pcm = _PcmLayout.read(source);
  if (pcm == null || pcm.frames <= 0 || bins <= 0) return null;
  final sums = Float64List(bins);
  final counts = Int32List(bins);
  final framesPerBlock = (_blockBytes ~/ pcm.frameBytes).clamp(1, 256);
  final framesPerBin = pcm.frames / bins;
  for (var b = 0; b < bins; b++) {
    final start = (b * framesPerBin).floor();
    final end = math.min(pcm.frames, ((b + 1) * framesPerBin).floor());
    final length = end - start;
    if (length <= 0) continue;
    final whole = length <= _blocksPerBin * framesPerBlock;
    final blocks = whole ? 1 : _blocksPerBin;
    final blockFrames = whole ? length : framesPerBlock;
    final gap = blocks == 1 ? 0.0 : (length - blockFrames) / (blocks - 1);
    for (var k = 0; k < blocks; k++) {
      final first = start + (k * gap).floor();
      final chunk = source.read(pcm.offset + first * pcm.frameBytes, blockFrames * pcm.frameBytes);
      final data = ByteData.sublistView(chunk);
      final frames = chunk.length ~/ pcm.frameBytes;
      for (var f = 0; f < frames; f++) {
        final base = f * pcm.frameBytes;
        for (var ch = 0; ch < pcm.channels; ch++) {
          final v = pcm.sample(data, base + ch * pcm.sampleBytes);
          sums[b] += v * v;
          counts[b]++;
        }
      }
    }
  }
  var loudest = 0.0;
  final rms = List<double>.filled(bins, 0);
  for (var b = 0; b < bins; b++) {
    rms[b] = counts[b] == 0 ? 0 : math.sqrt(sums[b] / counts[b]);
    loudest = math.max(loudest, rms[b]);
  }
  if (loudest <= 0) return rms;
  return [for (final r in rms) (r / loudest).clamp(0.0, 1.0)];
}

/// A waveform-like shape for a sound NEFORUM cannot decode: smooth hills with
/// detail, the same for the same [seed] (stableHash of the file's identity).
List<double> decorativeWaveform(int seed, {int bins = kWaveformBins}) {
  var state = seed & 0x7FFFFFFF;
  if (state == 0) state = 0x2545F491;
  double next() {
    // xorshift32: the same numbers on every platform and run.
    state ^= (state << 13) & 0xFFFFFFFF;
    state ^= state >> 17;
    state ^= (state << 5) & 0xFFFFFFFF;
    state &= 0xFFFFFFFF;
    return state / 0xFFFFFFFF;
  }

  final phases = [for (var i = 0; i < 4; i++) next() * math.pi * 2];
  final out = <double>[];
  for (var i = 0; i < bins; i++) {
    final t = i / bins;
    final hills = 0.55 + 0.25 * math.sin(t * math.pi * 3 + phases[0]) + 0.15 * math.sin(t * math.pi * 7 + phases[1]);
    final detail = 0.6 + 0.4 * next();
    final envelope = math.min(1.0, math.min(t, 1 - t) * 14 + 0.15);
    out.add((hills * detail * envelope).clamp(0.05, 1.0));
  }
  final loudest = out.reduce(math.max);
  return [for (final v in out) v / loudest];
}

/// [levels] resampled to [count] values, each the loudest of its stretch, so
/// short peaks survive.
List<double> resampleLevels(List<double> levels, int count) {
  if (levels.isEmpty || count <= 0) return List<double>.filled(math.max(0, count), 0);
  return [
    for (var i = 0; i < count; i++)
      () {
        final a = (i * levels.length / count).floor();
        final b = math.max(a + 1, ((i + 1) * levels.length / count).floor());
        var m = 0.0;
        for (var j = a; j < b && j < levels.length; j++) {
          m = math.max(m, levels[j]);
        }
        return m;
      }(),
  ];
}

/// Where the samples of a PCM file are and how they are written.
class _PcmLayout {
  _PcmLayout({
    required this.offset,
    required this.frames,
    required this.channels,
    required this.sampleBytes,
    required this.float,
    required this.bigEndian,
  });

  final int offset;
  final int frames;
  final int channels;
  final int sampleBytes;
  final bool float;
  final bool bigEndian;

  int get frameBytes => channels * sampleBytes;

  /// The sample at [at], -1 to 1.
  double sample(ByteData d, int at) {
    final e = bigEndian ? Endian.big : Endian.little;
    if (float) return sampleBytes == 8 ? d.getFloat64(at, e) : d.getFloat32(at, e);
    switch (sampleBytes) {
      case 1:
        // 8-bit WAV is unsigned; 8-bit AIFF is signed.
        return bigEndian ? d.getInt8(at) / 128 : (d.getUint8(at) - 128) / 128;
      case 2:
        return d.getInt16(at, e) / 32768;
      case 3:
        final b0 = d.getUint8(at), b1 = d.getUint8(at + 1), b2 = d.getUint8(at + 2);
        var v = bigEndian ? (b0 << 16 | b1 << 8 | b2) : (b2 << 16 | b1 << 8 | b0);
        if (v & 0x800000 != 0) v -= 0x1000000;
        return v / 8388608;
      default:
        return d.getInt32(at, e) / 2147483648;
    }
  }

  static String _tag(Uint8List b, int at) => at + 4 <= b.length ? String.fromCharCodes(b, at, at + 4) : '';

  /// The layout read from [s]'s chunk headers (and its `fmt ` or `COMM`
  /// chunk), without reading the samples.
  static _PcmLayout? read(PcmSource s) {
    final head = s.read(0, 12);
    if (head.length < 12) return null;
    final kind = _tag(head, 8);
    if (_tag(head, 0) == 'RIFF' && kind == 'WAVE') return _wav(s);
    if (_tag(head, 0) == 'FORM' && (kind == 'AIFF' || kind == 'AIFC')) return _aiff(s, compressed: kind == 'AIFC');
    return null;
  }

  static _PcmLayout? _wav(PcmSource s) {
    int? format, channels, bits;
    var at = 12;
    while (at + 8 <= s.length) {
      final header = s.read(at, 8);
      if (header.length < 8) return null;
      final id = _tag(header, 0);
      final size = ByteData.sublistView(header).getUint32(4, Endian.little);
      final body = at + 8;
      if (id == 'fmt ') {
        final b = s.read(body, math.min(size, 40));
        final d = ByteData.sublistView(b);
        if (b.length >= 16) {
          format = d.getUint16(0, Endian.little);
          channels = d.getUint16(2, Endian.little);
          bits = d.getUint16(14, Endian.little);
          // WAVE_FORMAT_EXTENSIBLE: the real format is the sub-format GUID's
          // first two bytes.
          if (format == 0xFFFE && size >= 26 && b.length >= 26) format = d.getUint16(24, Endian.little);
        }
      } else if (id == 'data') {
        if (format == null || channels == null || bits == null || channels == 0) return null;
        final float = format == 3;
        if (format != 1 && !float) return null;
        final sampleBytes = (bits + 7) ~/ 8;
        if (sampleBytes < 1 || sampleBytes > 8 || (float && sampleBytes != 4 && sampleBytes != 8)) return null;
        final length = math.min(size, s.length - body);
        return _PcmLayout(
            offset: body, frames: length ~/ (channels * sampleBytes), channels: channels, sampleBytes: sampleBytes, float: float, bigEndian: false);
      }
      at = body + size + (size & 1);
    }
    return null;
  }

  static _PcmLayout? _aiff(PcmSource s, {required bool compressed}) {
    int? channels, bits;
    var bigEndian = true, float = false;
    var at = 12;
    while (at + 8 <= s.length) {
      final header = s.read(at, 8);
      if (header.length < 8) return null;
      final id = _tag(header, 0);
      final size = ByteData.sublistView(header).getUint32(4, Endian.big);
      final body = at + 8;
      final b = id == 'COMM' || id == 'SSND' ? s.read(body, 22) : Uint8List(0);
      final d = ByteData.sublistView(b);
      if (id == 'COMM' && b.length >= 18) {
        channels = d.getUint16(0, Endian.big);
        bits = d.getUint16(6, Endian.big);
        if (compressed && b.length >= 22) {
          switch (_tag(b, 18)) {
            case 'NONE':
            case 'twos':
              break;
            case 'sowt':
              bigEndian = false;
            case 'fl32':
            case 'FL32':
              float = true;
              bits = 32;
            case 'fl64':
            case 'FL64':
              float = true;
              bits = 64;
            default:
              return null;
          }
        }
      } else if (id == 'SSND' && b.length >= 8) {
        if (channels == null || bits == null || channels == 0) return null;
        final dataOffset = d.getUint32(0, Endian.big);
        final start = body + 8 + dataOffset;
        final sampleBytes = (bits + 7) ~/ 8;
        if (sampleBytes < 1 || sampleBytes > 8) return null;
        final length = math.max(0, math.min(size - 8 - dataOffset, s.length - start));
        return _PcmLayout(
            offset: start, frames: length ~/ (channels * sampleBytes), channels: channels, sampleBytes: sampleBytes, float: float, bigEndian: bigEndian);
      }
      at = body + size + (size & 1);
    }
    return null;
  }
}

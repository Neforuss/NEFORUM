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

/// Files larger than this are not read for their levels (a decorative
/// waveform is drawn instead): hours of uncompressed sound.
const int kWaveformMaxBytes = 512 * 1024 * 1024;

/// The levels of the PCM sound in [bytes] (a WAV or AIFF file), as the RMS of
/// [bins] equal stretches of it over every channel, scaled so the loudest is
/// 1; null when [bytes] is not PCM NEFORUM can read. Top level, for
/// `compute`.
List<double>? measurePcmWaveform(Uint8List bytes, {int bins = kWaveformBins}) {
  final pcm = _PcmLayout.read(bytes);
  if (pcm == null || pcm.frames <= 0) return null;
  final sums = Float64List(bins);
  final counts = Int32List(bins);
  // At most this many frames per bin are read: plenty for its loudness, and
  // a long file stays quick.
  const perBin = 4096;
  final framesPerBin = pcm.frames / bins;
  final step = math.max(1, (framesPerBin / perBin).floor());
  final data = ByteData.sublistView(bytes);
  for (var b = 0; b < bins; b++) {
    final start = (b * framesPerBin).floor();
    final end = math.min(pcm.frames, ((b + 1) * framesPerBin).floor());
    for (var f = start; f < end; f += step) {
      final base = pcm.offset + f * pcm.frameBytes;
      for (var ch = 0; ch < pcm.channels; ch++) {
        final v = pcm.sample(data, base + ch * pcm.sampleBytes);
        sums[b] += v * v;
        counts[b]++;
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

  static _PcmLayout? read(Uint8List b) {
    if (b.length < 12) return null;
    final head = _tag(b, 0);
    if (head == 'RIFF' && _tag(b, 8) == 'WAVE') return _wav(b);
    if (head == 'FORM' && (_tag(b, 8) == 'AIFF' || _tag(b, 8) == 'AIFC')) return _aiff(b, compressed: _tag(b, 8) == 'AIFC');
    return null;
  }

  static _PcmLayout? _wav(Uint8List b) {
    final d = ByteData.sublistView(b);
    int? format, channels, bits;
    var at = 12;
    while (at + 8 <= b.length) {
      final id = _tag(b, at);
      final size = d.getUint32(at + 4, Endian.little);
      final body = at + 8;
      if (id == 'fmt ' && body + 16 <= b.length) {
        format = d.getUint16(body, Endian.little);
        channels = d.getUint16(body + 2, Endian.little);
        bits = d.getUint16(body + 14, Endian.little);
        // WAVE_FORMAT_EXTENSIBLE: the real format is the sub-format GUID's
        // first two bytes.
        if (format == 0xFFFE && size >= 26 && body + 26 <= b.length) format = d.getUint16(body + 24, Endian.little);
      } else if (id == 'data') {
        if (format == null || channels == null || bits == null || channels == 0) return null;
        final float = format == 3;
        if (format != 1 && !float) return null;
        final sampleBytes = (bits + 7) ~/ 8;
        if (sampleBytes < 1 || sampleBytes > 8 || (float && sampleBytes != 4 && sampleBytes != 8)) return null;
        final length = math.min(size, b.length - body);
        return _PcmLayout(
            offset: body, frames: length ~/ (channels * sampleBytes), channels: channels, sampleBytes: sampleBytes, float: float, bigEndian: false);
      }
      at = body + size + (size & 1);
    }
    return null;
  }

  static _PcmLayout? _aiff(Uint8List b, {required bool compressed}) {
    final d = ByteData.sublistView(b);
    int? channels, bits;
    var bigEndian = true, float = false;
    var at = 12;
    while (at + 8 <= b.length) {
      final id = _tag(b, at);
      final size = d.getUint32(at + 4, Endian.big);
      final body = at + 8;
      if (id == 'COMM' && body + 18 <= b.length) {
        channels = d.getUint16(body, Endian.big);
        bits = d.getUint16(body + 6, Endian.big);
        if (compressed && body + 22 <= b.length) {
          switch (_tag(b, body + 18)) {
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
      } else if (id == 'SSND' && body + 8 <= b.length) {
        if (channels == null || bits == null || channels == 0) return null;
        final dataOffset = d.getUint32(body, Endian.big);
        final start = body + 8 + dataOffset;
        final sampleBytes = (bits + 7) ~/ 8;
        if (sampleBytes < 1 || sampleBytes > 8) return null;
        final length = math.max(0, math.min(size - 8 - dataOffset, b.length - start));
        return _PcmLayout(
            offset: start, frames: length ~/ (channels * sampleBytes), channels: channels, sampleBytes: sampleBytes, float: float, bigEndian: bigEndian);
      }
      at = body + size + (size & 1);
    }
    return null;
  }
}

import '../media/waveform.dart';
import 'pcm_file_web.dart' if (dart.library.io) 'pcm_file_io.dart' as impl;

/// The levels of the WAV or AIFF file at [path] ([measurePcmSource]), read in
/// parts: its chunk headers and a few blocks of frames per bin, never the
/// whole file. Null when it is not PCM NEFORUM can read or cannot be opened,
/// and on the web, which has no files. Synchronous: run it off the UI
/// isolate, from a top-level function.
List<double>? measurePcmFile(String path, {int bins = kWaveformBins}) => impl.measurePcmFile(path, bins: bins);

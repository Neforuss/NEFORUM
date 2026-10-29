import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../media/waveform.dart';

List<double>? measurePcmFile(String path, {required int bins}) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    return measurePcmSource(_FilePcmSource(file), bins: bins);
  } on FileSystemException {
    return null;
  } finally {
    file?.closeSync();
  }
}

/// A [PcmSource] reading an open file at the positions asked for.
class _FilePcmSource implements PcmSource {
  _FilePcmSource(this._file) : length = _file.lengthSync();
  final RandomAccessFile _file;

  @override
  final int length;

  @override
  Uint8List read(int offset, int count) {
    if (offset < 0 || offset >= length || count <= 0) return Uint8List(0);
    _file.setPositionSync(offset);
    return _file.readSync(math.min(count, length - offset));
  }
}

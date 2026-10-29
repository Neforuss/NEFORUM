#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// The "neforum/clipboard" channel (lib/platform/clipboard_media.dart):
//
// * copyImage {png: Uint8List, path?: String} -> bool
//   Puts the picture on the CLIPBOARD selection, where browsers and other
//   apps read it on Ctrl+V.
// * readImage -> {files: [String]} | {png: Uint8List} | {}
//   What a paste into the composer can attach: files copied in a file
//   manager, or a picture (a screenshot, "Copy image" in a browser) as PNG.
//
// The caller keeps the returned channel alive (g_object_unref to release).
FlMethodChannel* clipboard_channel_new(FlBinaryMessenger* messenger);

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_

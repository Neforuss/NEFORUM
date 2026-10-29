#ifndef RUNNER_DESKTOP_CHANNEL_H_
#define RUNNER_DESKTOP_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// The "neforum/desktop" channel (lib/platform/desktop_io.dart):
//
// * statusNotifierHostAvailable -> bool
//   Whether the desktop shows tray icons (StatusNotifierItem): a
//   StatusNotifierWatcher runs on the session bus and a host (a panel)
//   registered with it. Plain GNOME has none without the AppIndicator
//   extension, and there "close to the tray" would hide the window with no
//   icon to bring it back.
//
// The caller keeps the returned channel alive (g_object_unref to release).
FlMethodChannel* desktop_channel_new(FlBinaryMessenger* messenger);

#endif  // RUNNER_DESKTOP_CHANNEL_H_

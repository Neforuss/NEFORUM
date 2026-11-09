// A stand-in for desktop_webview_window's Linux plugin (NEFORUM 1.4.2).
//
// That plugin comes with flutter_web_auth_2, which NEFORUM uses for sign-in
// only on Android, iOS and macOS; on Linux sign-in goes through a loopback
// server and the person's own browser (lib/platform/app_auth_broker.dart).
// The real plugin links WebKitGTK 4.1, so the whole app failed to start on a
// system without it (the AppImage catalog's test: "libwebkit2gtk-4.1.so.0:
// cannot open shared object file"). This library takes its place in the
// bundle under the same file name and only answers the registration call the
// generated plugin registrant makes.

struct _FlPluginRegistrar;

extern "C" __attribute__((visibility("default"))) void desktop_webview_window_plugin_register_with_registrar(
    struct _FlPluginRegistrar* registrar) {
  (void)registrar;
}

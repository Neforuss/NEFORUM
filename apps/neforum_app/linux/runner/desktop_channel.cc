#include "desktop_channel.h"

#include <gio/gio.h>

namespace {

// The watcher's well-known names: KDE's specification name, and the name
// older Ayatana/Canonical panels use. Each serves the interface of the same
// name at /StatusNotifierWatcher.
const char* const kWatcherNames[] = {
    "org.kde.StatusNotifierWatcher",
    "com.canonical.StatusNotifierWatcher",
};

bool StatusNotifierHostAvailable() {
  g_autoptr(GDBusConnection) bus =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (bus == nullptr) return false;
  for (const char* name : kWatcherNames) {
    // NO_AUTO_START: asking must not start a watcher that is not running.
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
        bus, name, "/StatusNotifierWatcher", "org.freedesktop.DBus.Properties",
        "Get", g_variant_new("(ss)", name, "IsStatusNotifierHostRegistered"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 500, nullptr,
        nullptr);
    if (reply == nullptr) continue;
    g_autoptr(GVariant) value = nullptr;
    g_variant_get(reply, "(v)", &value);
    if (value != nullptr &&
        g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN) &&
        g_variant_get_boolean(value)) {
      return true;
    }
  }
  return false;
}

void HandleMethodCall(FlMethodChannel* channel, FlMethodCall* method_call,
                      gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "statusNotifierHostAvailable") == 0) {
    g_autoptr(FlValue) result =
        fl_value_new_bool(StatusNotifierHostAvailable());
    fl_method_call_respond_success(method_call, result, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

}  // namespace

FlMethodChannel* desktop_channel_new(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, "neforum/desktop", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, HandleMethodCall, nullptr,
                                            nullptr);
  return channel;
}

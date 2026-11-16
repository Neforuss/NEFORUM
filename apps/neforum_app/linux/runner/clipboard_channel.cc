#include "clipboard_channel.h"

#include <gtk/gtk.h>

#include <cstring>

namespace {

GtkClipboard* SystemClipboard() {
  return gtk_clipboard_get_for_display(gdk_display_get_default(),
                                       GDK_SELECTION_CLIPBOARD);
}

// A pixbuf from PNG bytes; nullptr when they are not a readable PNG.
GdkPixbuf* PixbufFromPng(const uint8_t* data, size_t size) {
  GdkPixbufLoader* loader = gdk_pixbuf_loader_new_with_type("png", nullptr);
  if (loader == nullptr) return nullptr;
  gboolean written = gdk_pixbuf_loader_write(loader, data, size, nullptr);
  gboolean closed = gdk_pixbuf_loader_close(loader, nullptr);
  GdkPixbuf* pixbuf = nullptr;
  if (written && closed) {
    GdkPixbuf* decoded = gdk_pixbuf_loader_get_pixbuf(loader);
    if (decoded != nullptr) pixbuf = GDK_PIXBUF(g_object_ref(decoded));
  }
  g_object_unref(loader);
  return pixbuf;
}

// Puts the picture in |args|["png"] on the clipboard. GTK offers it in every
// image format the system can write (image/png first), converted when an
// app asks for it. The original file (|args|["path"]) is not offered next to
// it: with a file list on the clipboard, some editors paste the path as text
// instead of the picture.
bool CopyImage(FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  FlValue* png = fl_value_lookup_string(args, "png");
  if (png == nullptr || fl_value_get_type(png) != FL_VALUE_TYPE_UINT8_LIST ||
      fl_value_get_length(png) == 0) {
    return false;
  }
  GdkPixbuf* pixbuf =
      PixbufFromPng(fl_value_get_uint8_list(png), fl_value_get_length(png));
  if (pixbuf == nullptr) return false;
  GtkClipboard* clipboard = SystemClipboard();
  gtk_clipboard_set_image(clipboard, pixbuf);
  // A clipboard manager may keep the picture after NEFORUM quits.
  gtk_clipboard_set_can_store(clipboard, nullptr, 0);
  g_object_unref(pixbuf);
  return true;
}

// 1.4.4: articles. Formatted text: text/html for editors that paste
// formatting, and the words as plain text for the rest. GTK asks for the
// data when an app pastes; NEFORUM keeps it until the clipboard changes.
struct HtmlClip {
  gchar* html;
  gchar* text;
};

enum { kTargetHtml = 1, kTargetText = 2 };

void GetHtmlClip(GtkClipboard* clipboard, GtkSelectionData* selection,
                 guint info, gpointer user_data) {
  auto* clip = static_cast<HtmlClip*>(user_data);
  if (info == kTargetHtml) {
    gtk_selection_data_set(selection, gtk_selection_data_get_target(selection),
                           8, reinterpret_cast<const guchar*>(clip->html),
                           static_cast<gint>(strlen(clip->html)));
  } else {
    gtk_selection_data_set_text(selection, clip->text, -1);
  }
}

void ClearHtmlClip(GtkClipboard* clipboard, gpointer user_data) {
  auto* clip = static_cast<HtmlClip*>(user_data);
  g_free(clip->html);
  g_free(clip->text);
  g_free(clip);
}

bool CopyHtml(FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  FlValue* html = fl_value_lookup_string(args, "html");
  FlValue* text = fl_value_lookup_string(args, "text");
  const gchar* h = html != nullptr && fl_value_get_type(html) == FL_VALUE_TYPE_STRING
                       ? fl_value_get_string(html)
                       : "";
  const gchar* t = text != nullptr && fl_value_get_type(text) == FL_VALUE_TYPE_STRING
                       ? fl_value_get_string(text)
                       : "";
  if (*h == '\0' && *t == '\0') return false;
  auto* clip = g_new0(HtmlClip, 1);
  clip->html = g_strdup(h);
  clip->text = g_strdup(t);
  GtkTargetList* list = gtk_target_list_new(nullptr, 0);
  if (*h != '\0') {
    gtk_target_list_add(list, gdk_atom_intern_static_string("text/html"), 0, kTargetHtml);
  }
  gtk_target_list_add_text_targets(list, kTargetText);
  gint count = 0;
  GtkTargetEntry* targets = gtk_target_table_new_from_list(list, &count);
  GtkClipboard* clipboard = SystemClipboard();
  gboolean set = gtk_clipboard_set_with_data(clipboard, targets, count, GetHtmlClip, ClearHtmlClip, clip);
  if (set) gtk_clipboard_set_can_store(clipboard, nullptr, 0);
  gtk_target_table_free(targets, count);
  gtk_target_list_unref(list);
  if (!set) ClearHtmlClip(clipboard, clip);
  return set;
}

void RespondWithImage(GtkClipboard* clipboard, GdkPixbuf* pixbuf,
                      gpointer user_data) {
  FlMethodCall* method_call = FL_METHOD_CALL(user_data);
  g_autoptr(FlValue) result = fl_value_new_map();
  if (pixbuf != nullptr) {
    gchar* buffer = nullptr;
    gsize size = 0;
    if (gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &size, "png", nullptr,
                                  nullptr) &&
        buffer != nullptr && size > 0) {
      fl_value_set_string_take(
          result, "png",
          fl_value_new_uint8_list(reinterpret_cast<const uint8_t*>(buffer),
                                  size));
    }
    g_free(buffer);
  }
  fl_method_call_respond_success(method_call, result, nullptr);
  g_object_unref(method_call);
}

// Files copied in a file manager come first (text/uri-list); otherwise the
// picture, if there is one.
void RespondWithFilesOrImage(GtkClipboard* clipboard, gchar** uris,
                             gpointer user_data) {
  FlMethodCall* method_call = FL_METHOD_CALL(user_data);
  g_autoptr(FlValue) files = fl_value_new_list();
  for (gchar** uri = uris; uri != nullptr && *uri != nullptr; uri++) {
    gchar* path = g_filename_from_uri(*uri, nullptr, nullptr);
    if (path == nullptr) continue;
    fl_value_append_take(files, fl_value_new_string(path));
    g_free(path);
  }
  if (fl_value_get_length(files) > 0) {
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string(result, "files", files);
    fl_method_call_respond_success(method_call, result, nullptr);
    g_object_unref(method_call);
    return;
  }
  gtk_clipboard_request_image(clipboard, RespondWithImage, method_call);
}

void HandleMethodCall(FlMethodChannel* channel, FlMethodCall* method_call,
                      gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "copyImage") == 0) {
    g_autoptr(FlValue) result =
        fl_value_new_bool(CopyImage(fl_method_call_get_args(method_call)));
    fl_method_call_respond_success(method_call, result, nullptr);
    return;
  }
  if (g_strcmp0(method, "copyHtml") == 0) {
    g_autoptr(FlValue) result =
        fl_value_new_bool(CopyHtml(fl_method_call_get_args(method_call)));
    fl_method_call_respond_success(method_call, result, nullptr);
    return;
  }
  if (g_strcmp0(method, "readImage") == 0) {
    // Answered from the callbacks, which hold the call until then.
    gtk_clipboard_request_uris(SystemClipboard(), RespondWithFilesOrImage,
                               g_object_ref(method_call));
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

}  // namespace

FlMethodChannel* clipboard_channel_new(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, "neforum/clipboard", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, HandleMethodCall, nullptr,
                                            nullptr);
  return channel;
}

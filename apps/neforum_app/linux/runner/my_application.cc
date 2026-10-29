#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "clipboard_channel.h"
#include "desktop_channel.h"
#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // The one NEFORUM window; cleared by a weak pointer when it is destroyed.
  GtkWindow* window;
  FlMethodChannel* clipboard_channel;
  FlMethodChannel* desktop_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Launched at login with --minimized: the window stays hidden until the tray
// icon (or a second launch) brings it up. lib/platform/desktop_io.dart shows
// it anyway when the desktop has no tray.
static gboolean starts_hidden(MyApplication* self) {
  for (char** arg = self->dart_entrypoint_arguments;
       arg != nullptr && *arg != nullptr; arg++) {
    if (g_strcmp0(*arg, "--minimized") == 0) return TRUE;
  }
  return FALSE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  if (starts_hidden(self)) return;
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// The app icon from the bundle (data/flutter_assets/assets/brand/icon.png
// next to the executable), for window managers that show it. Installed
// copies (Flatpak, distribution packages) also find it by the application id
// through the .desktop file.
static void set_window_icon(GtkWindow* window) {
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable == nullptr) return;
  g_autofree gchar* directory = g_path_get_dirname(executable);
  g_autofree gchar* icon = g_build_filename(
      directory, "data", "flutter_assets", "assets", "brand", "icon.png",
      nullptr);
  if (g_file_test(icon, G_FILE_TEST_EXISTS)) {
    gtk_window_set_icon_from_file(window, icon, nullptr);
  } else {
    gtk_window_set_icon_name(window, APPLICATION_ID);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // One NEFORUM at a time: a second copy would run a second scheduler and
  // could publish the same post twice. GApplication's unique mode sends a
  // second launch's activation here; bring the window forward instead (it
  // may be hidden in the tray).
  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->window));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "NEFORUM");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  }
  gtk_window_set_title(window, "NEFORUM");
  set_window_icon(window);

  gtk_window_set_default_size(window, 1320, 860);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "NeforumRunner");
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  self->clipboard_channel = clipboard_channel_new(messenger);
  self->desktop_channel = desktop_channel_new(messenger);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  // Registering finds out whether NEFORUM already runs for this user (on the
  // session bus). If it does, the activation below goes to that copy and
  // this process ends.
  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->clipboard_channel);
  g_clear_object(&self->desktop_channel);
  if (self->window != nullptr) {
    g_object_remove_weak_pointer(G_OBJECT(self->window),
                                 reinterpret_cast<gpointer*>(&self->window));
    self->window = nullptr;
  }
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // Unique (no G_APPLICATION_NON_UNIQUE): one instance per user session.
  // Without a session bus GApplication runs as a normal, non-unique app.
  // The flags are spelled as 0: G_APPLICATION_DEFAULT_FLAGS needs GLib 2.74
  // (Ubuntu 22.04 has 2.72), and G_APPLICATION_FLAGS_NONE is deprecated
  // from 2.74 on, which -Werror turns into a build failure there.
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     static_cast<GApplicationFlags>(0),
                                     nullptr));
}

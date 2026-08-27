#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <cstdint>
#include <cstring>
#include <string>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "activity_sensor.h"
#include "amadeus_core.h"
#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* activity_channel;
  gboolean activity_sensor_ready_logged;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static std::uint64_t read_idle_threshold(FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return 300;
  }
  FlValue* value = fl_value_lookup_string(args, "idleThreshold");
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return 300;
  }
  const std::int64_t threshold = fl_value_get_int(value);
  return threshold > 0 ? static_cast<std::uint64_t>(threshold) : 1;
}

static std::string read_excluded_apps(FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return "";
  }
  FlValue* value = fl_value_lookup_string(args, "excludedApps");
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_LIST) {
    return "";
  }

  std::string result;
  for (size_t index = 0; index < fl_value_get_length(value); ++index) {
    FlValue* item = fl_value_get_list_value(value, index);
    if (item == nullptr || fl_value_get_type(item) != FL_VALUE_TYPE_STRING) {
      continue;
    }
    const gchar* value_text = fl_value_get_string(item);
    if (value_text == nullptr || std::strchr(value_text, '\n') != nullptr ||
        std::strchr(value_text, '\r') != nullptr) {
      continue;
    }
    if (!result.empty()) result.push_back('\n');
    result.append(value_text);
  }
  return result;
}

static void activity_method_call_cb(FlMethodChannel* channel,
                                    FlMethodCall* method_call,
                                    gpointer user_data) {
  (void)channel;
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (std::strcmp(fl_method_call_get_name(method_call), "getSnapshot") != 0) {
    response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  } else {
    amadeus::ActivitySample sample;
    std::string error_code;
    std::string error_message;
    if (!amadeus::ReadActivitySample(&sample, &error_code, &error_message)) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          error_code.c_str(), error_message.c_str(), nullptr));
    } else {
      if (!self->activity_sensor_ready_logged) {
        self->activity_sensor_ready_logged = TRUE;
        g_message("activity: Linux X11 sensor ready");
      }
      FlValue* args = fl_method_call_get_args(method_call);
      const std::uint64_t idle_threshold = read_idle_threshold(args);
      const std::string excluded_apps = read_excluded_apps(args);
      const std::int32_t decision = amadeus_activity_classify(
          sample.app_name.c_str(), sample.idle_seconds, idle_threshold,
          excluded_apps.c_str());

      g_autoptr(FlValue) result = fl_value_new_map();
      fl_value_set_string_take(
          result, "appName", fl_value_new_string(sample.app_name.c_str()));
      fl_value_set_string_take(
          result, "appId", fl_value_new_string(sample.app_id.c_str()));
      fl_value_set_string_take(
          result, "idleSeconds",
          fl_value_new_int(static_cast<std::int64_t>(sample.idle_seconds)));
      fl_value_set_string_take(result, "decision",
                               fl_value_new_int(decision));
      fl_value_set_string_take(
          result, "coreVersion",
          fl_value_new_int(static_cast<std::int64_t>(amadeus_core_version())));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond on Amadeus activity channel: %s",
              error->message);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

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
    gtk_header_bar_set_title(header_bar, "Amadeus");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Amadeus");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#00000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_clear_object(&self->activity_channel);
  self->activity_channel = fl_method_channel_new(
      messenger, "amadeus/activity", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->activity_channel, activity_method_call_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

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
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_object(&self->activity_channel);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
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

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}

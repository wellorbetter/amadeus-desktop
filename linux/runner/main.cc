#include "my_application.h"

#include <cstring>
#include <string>

#include "activity_sensor.h"

namespace {

int RunActivitySensorSmoke(char* executable_name) {
  int gtk_argc = 1;
  char* gtk_argv_values[] = {executable_name, nullptr};
  char** gtk_argv = gtk_argv_values;
  gtk_init(&gtk_argc, &gtk_argv);

  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), "Amadeus activity sensor smoke");
  gtk_window_set_default_size(GTK_WINDOW(window), 320, 180);
  gtk_widget_show_all(window);
  gtk_window_present(GTK_WINDOW(window));

  std::string error_code = "foreground_unavailable";
  std::string error_message = "No active X11 window was observed.";
  for (int attempt = 0; attempt < 50; ++attempt) {
    while (g_main_context_iteration(nullptr, FALSE)) {
    }
    amadeus::ActivitySample sample;
    if (amadeus::ReadActivitySample(&sample, &error_code, &error_message)) {
      g_print("activity: Linux X11 sensor ready\n");
      gtk_widget_destroy(window);
      return 0;
    }
    g_usleep(100 * 1000);
  }

  g_printerr("activity: Linux sensor unavailable (%s): %s\n",
             error_code.c_str(), error_message.c_str());
  gtk_widget_destroy(window);
  return 1;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 2 &&
      std::strcmp(argv[1], "--activity-sensor-smoke") == 0) {
    return RunActivitySensorSmoke(argv[0]);
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}

#include "activity_sensor.h"

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/extensions/scrnsaver.h>
#include <gdk/gdkx.h>

#include <algorithm>
#include <limits>
#include <string>

namespace amadeus {
namespace {

bool ReadWindowProperty(Display* display,
                        Window window,
                        Atom property,
                        Atom expected_type,
                        unsigned long* value) {
  if (property == None || value == nullptr) return false;

  Atom actual_type = None;
  int actual_format = 0;
  unsigned long item_count = 0;
  unsigned long bytes_after = 0;
  unsigned char* data = nullptr;
  const int status = XGetWindowProperty(
      display, window, property, 0, 1, False, expected_type, &actual_type,
      &actual_format, &item_count, &bytes_after, &data);
  if (status != Success || data == nullptr || actual_type != expected_type ||
      actual_format != 32 || item_count != 1) {
    if (data != nullptr) XFree(data);
    return false;
  }

  *value = *reinterpret_cast<unsigned long*>(data);
  XFree(data);
  return true;
}

bool IsSafeProcessName(const std::string& value) {
  if (value.empty() || !g_utf8_validate(value.c_str(), -1, nullptr)) {
    return false;
  }
  return std::none_of(value.begin(), value.end(), [](unsigned char character) {
    return character < 0x20 || character == 0x7f;
  });
}

bool ReadProcessName(unsigned long pid, std::string* app_name) {
  if (pid == 0 || pid > std::numeric_limits<int>::max() ||
      app_name == nullptr) {
    return false;
  }

  g_autofree gchar* path = g_strdup_printf("/proc/%lu/comm", pid);
  g_autofree gchar* contents = nullptr;
  if (!g_file_get_contents(path, &contents, nullptr, nullptr) ||
      contents == nullptr) {
    return false;
  }
  g_strchomp(contents);
  const std::string value(contents);
  if (!IsSafeProcessName(value)) return false;
  *app_name = value;
  return true;
}

bool ReadIdleSeconds(Display* display, std::uint64_t* idle_seconds) {
  if (idle_seconds == nullptr) return false;
  XScreenSaverInfo* info = XScreenSaverAllocInfo();
  if (info == nullptr) return false;
  const Status status =
      XScreenSaverQueryInfo(display, DefaultRootWindow(display), info);
  if (status == 0) {
    XFree(info);
    return false;
  }
  *idle_seconds = static_cast<std::uint64_t>(info->idle) / 1000;
  XFree(info);
  return true;
}

void SetError(std::string* error_code,
              std::string* error_message,
              const char* code,
              const char* message) {
  if (error_code != nullptr) *error_code = code;
  if (error_message != nullptr) *error_message = message;
}

}  // namespace

bool ReadActivitySample(ActivitySample* sample,
                        std::string* error_code,
                        std::string* error_message) {
  if (sample == nullptr) {
    SetError(error_code, error_message, "invalid_state",
             "Activity sample destination is missing.");
    return false;
  }

  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == nullptr || !GDK_IS_X11_DISPLAY(gdk_display)) {
    SetError(error_code, error_message, "unsupported_session",
             "Global application activity is unavailable in this Wayland "
             "session.");
    return false;
  }

  Display* display = gdk_x11_display_get_xdisplay(gdk_display);
  const Window root = DefaultRootWindow(display);
  const Atom active_window_atom =
      XInternAtom(display, "_NET_ACTIVE_WINDOW", True);
  unsigned long active_window_value = 0;
  if (!ReadWindowProperty(display, root, active_window_atom, XA_WINDOW,
                          &active_window_value) ||
      active_window_value == None) {
    SetError(error_code, error_message, "foreground_unavailable",
             "The X11 window manager did not expose an active window.");
    return false;
  }

  const Atom pid_atom = XInternAtom(display, "_NET_WM_PID", True);
  unsigned long pid = 0;
  if (!ReadWindowProperty(display, static_cast<Window>(active_window_value),
                          pid_atom, XA_CARDINAL, &pid) ||
      !ReadProcessName(pid, &sample->app_name)) {
    SetError(error_code, error_message, "process_unavailable",
             "The active X11 process identity could not be read.");
    return false;
  }

  if (!ReadIdleSeconds(display, &sample->idle_seconds)) {
    SetError(error_code, error_message, "idle_unavailable",
             "The X11 idle duration could not be read.");
    return false;
  }

  sample->app_id = "linux:" + sample->app_name;
  return true;
}

}  // namespace amadeus

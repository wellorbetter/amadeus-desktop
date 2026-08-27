#include "flutter_window.h"

#include <algorithm>
#include <optional>
#include <string>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "amadeus_core.h"

namespace {

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                       static_cast<int>(value.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}

std::wstring ForegroundProcessName(DWORD* process_id) {
  const HWND foreground = GetForegroundWindow();
  if (!foreground) return {};
  DWORD pid = 0;
  GetWindowThreadProcessId(foreground, &pid);
  if (process_id) *process_id = pid;
  if (!pid) return {};
  const HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return L"Process " + std::to_wstring(pid);
  std::wstring path(32768, L'\0');
  DWORD length = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &length)) {
    CloseHandle(process);
    return L"Process " + std::to_wstring(pid);
  }
  CloseHandle(process);
  path.resize(length);
  const auto slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

int64_t IdleSeconds() {
  LASTINPUTINFO info{sizeof(LASTINPUTINFO)};
  if (!GetLastInputInfo(&info)) return 0;
  const DWORD idle_ms = GetTickCount() - info.dwTime;
  return static_cast<int64_t>(idle_ms / 1000);
}

int64_t IntegerValue(const flutter::EncodableValue& value,
                     int64_t fallback) {
  if (const auto* i = std::get_if<int32_t>(&value)) return *i;
  if (const auto* i = std::get_if<int64_t>(&value)) return *i;
  if (const auto* d = std::get_if<double>(&value)) {
    return static_cast<int64_t>(*d);
  }
  return fallback;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "timepet/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "setHitRegion") {
          const auto* list = std::get_if<flutter::EncodableList>(call.arguments());
          if (list && list->size() == 4) {
            auto number = [](const flutter::EncodableValue& value) -> int {
              if (const auto* i = std::get_if<int32_t>(&value)) return *i;
              if (const auto* i = std::get_if<int64_t>(&value)) return static_cast<int>(*i);
              if (const auto* d = std::get_if<double>(&value)) return static_cast<int>(*d);
              return 0;
            };
            hit_region_ = {number((*list)[0]), number((*list)[1]),
                           number((*list)[0]) + number((*list)[2]),
                           number((*list)[1]) + number((*list)[3])};
            hit_region_enabled_ = hit_region_.right > hit_region_.left &&
                                  hit_region_.bottom > hit_region_.top;
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  activity_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "amadeus/activity",
          &flutter::StandardMethodCodec::GetInstance());
  activity_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() != "getSnapshot") {
          result->NotImplemented();
          return;
        }
        DWORD pid = 0;
        const auto process_name = ForegroundProcessName(&pid);
        const auto app_name = WideToUtf8(process_name);
        const auto idle_seconds = IdleSeconds();
        int64_t idle_threshold = 300;
        std::string exclusions;
        if (const auto* arguments =
                std::get_if<flutter::EncodableMap>(call.arguments())) {
          const auto threshold =
              arguments->find(flutter::EncodableValue("idleThreshold"));
          if (threshold != arguments->end()) {
            idle_threshold = IntegerValue(threshold->second, 300);
          }
          const auto excluded =
              arguments->find(flutter::EncodableValue("excludedApps"));
          if (excluded != arguments->end()) {
            if (const auto* values =
                    std::get_if<flutter::EncodableList>(&excluded->second)) {
              for (const auto& value : *values) {
                if (const auto* name = std::get_if<std::string>(&value)) {
                  if (!exclusions.empty()) exclusions += '\n';
                  exclusions += *name;
                }
              }
            }
          }
        }
        const auto decision = amadeus_activity_classify(
            app_name.c_str(), static_cast<uint64_t>(idle_seconds),
            static_cast<uint64_t>(std::max<int64_t>(1, idle_threshold)),
            exclusions.c_str());
        flutter::EncodableMap snapshot;
        snapshot[flutter::EncodableValue("appName")] =
            flutter::EncodableValue(app_name);
        // Deliberately expose an identifier, never the executable path.
        const auto process_id = WideToUtf8(process_name);
        snapshot[flutter::EncodableValue("appId")] = flutter::EncodableValue(
            process_id.empty()
                ? (pid == 0 ? std::string()
                            : "win32:process-" + std::to_string(pid))
                : "win32:" + process_id);
        snapshot[flutter::EncodableValue("idleSeconds")] =
            flutter::EncodableValue(idle_seconds);
        snapshot[flutter::EncodableValue("decision")] =
            flutter::EncodableValue(decision);
        snapshot[flutter::EncodableValue("coreVersion")] =
            flutter::EncodableValue(
                static_cast<int64_t>(amadeus_core_version()));
        result->Success(flutter::EncodableValue(snapshot));
      });
  RegisterPlugins(flutter_controller_->engine());
  // 子窗口（设置窗口）创建时同样注册所有插件
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    RegisterPlugins(registry);
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // ??????? Flutter ?????? WM_NCCALCSIZE?????=????
  // ?? DWM ? WS_POPUP ???????????????????"?"??
  if (message == WM_NCCALCSIZE && wparam) {
    return 0;
  }

  if (message == WM_NCHITTEST && hit_region_enabled_) {
    POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    ScreenToClient(hwnd, &point);
    const auto dpi = static_cast<double>(GetDpiForWindow(hwnd)) / 96.0;
    const POINT logical{static_cast<LONG>(point.x / dpi),
                        static_cast<LONG>(point.y / dpi)};
    if (!PtInRect(&hit_region_, logical)) return HTTRANSPARENT;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

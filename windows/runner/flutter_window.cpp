#include "flutter_window.h"

#include <optional>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"

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

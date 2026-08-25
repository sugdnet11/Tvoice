#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

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
  RegisterPlugins(flutter_controller_->engine());
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "tvoice/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "setFullscreen") {
          const auto* enabled = std::get_if<bool>(call.arguments());
          if (!enabled) {
            result->Error("invalid-arguments", "Fullscreen flag is required");
            return;
          }
          HWND hwnd = GetHandle();
          if (*enabled && !fullscreen_) {
            fullscreen_ = true;
            windowed_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
            GetWindowPlacement(hwnd, &windowed_placement_);
            MONITORINFO monitor{sizeof(MONITORINFO)};
            GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
            SetWindowLongPtr(hwnd, GWL_STYLE, windowed_style_ & ~WS_OVERLAPPEDWINDOW);
            SetWindowPos(hwnd, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
                         monitor.rcMonitor.right - monitor.rcMonitor.left,
                         monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                         SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
          } else if (!*enabled && fullscreen_) {
            fullscreen_ = false;
            SetWindowLongPtr(hwnd, GWL_STYLE, windowed_style_);
            SetWindowPlacement(hwnd, &windowed_placement_);
            SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                         SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE |
                             SWP_NOZORDER | SWP_NOOWNERZORDER);
          }
          result->Success();
          return;
        }
        if (call.method_name() != "setWindowMode") {
          result->NotImplemented();
          return;
        }
        const auto* mode =
            std::get_if<std::string>(call.arguments());
        if (mode == nullptr) {
          result->Error("invalid-arguments", "Window mode is required");
          return;
        }
        if (*mode == "splash") {
          SetWindowConfiguration(Size(560, 340), Size(480, 300), false);
        } else if (*mode == "login") {
          SetWindowConfiguration(Size(520, 560), Size(480, 520), true);
        } else if (*mode == "main") {
          SetWindowConfiguration(Size(1120, 720), Size(900, 620), true);
        } else {
          result->Error("invalid-mode", "Unknown Tvoice window mode");
          return;
        }
        result->Success();
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
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_COPYDATA: {
      const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (data && data->dwData == 0x54564F49 && data->lpData && window_channel_) {
        const auto* wide = static_cast<const wchar_t*>(data->lpData);
        const int size = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
        if (size > 1) {
          std::string value(static_cast<size_t>(size), '\0');
          WideCharToMultiByte(CP_UTF8, 0, wide, -1, value.data(), size, nullptr, nullptr);
          value.resize(static_cast<size_t>(size - 1));
          window_channel_->InvokeMethod(
              "onDeepLink",
              std::make_unique<flutter::EncodableValue>(value));
        }
      }
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

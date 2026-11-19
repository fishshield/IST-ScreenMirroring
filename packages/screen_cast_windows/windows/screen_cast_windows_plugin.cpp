#include "screen_cast_windows_plugin.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <cmath>
#include <cstdint>
#include <cwchar>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "hardware_frame_bridge.h"
#include "tray_icon.h"

namespace screen_cast_windows {

namespace {

constexpr char kChannelName[] = "dev.screencast/windows_view";

bool ReadNumber(const flutter::EncodableMap& arguments, const char* key,
                double* value) {
  const auto iterator =
      arguments.find(flutter::EncodableValue(std::string(key)));
  if (iterator == arguments.end()) {
    return false;
  }
  if (const auto* number = std::get_if<double>(&iterator->second)) {
    *value = *number;
    return true;
  }
  if (const auto* number = std::get_if<int32_t>(&iterator->second)) {
    *value = static_cast<double>(*number);
    return true;
  }
  if (const auto* number = std::get_if<int64_t>(&iterator->second)) {
    *value = static_cast<double>(*number);
    return true;
  }
  return false;
}

bool ReadBool(const flutter::EncodableMap& arguments, const char* key,
              bool* value) {
  const auto iterator =
      arguments.find(flutter::EncodableValue(std::string(key)));
  if (iterator == arguments.end()) {
    return false;
  }
  const auto* boolean = std::get_if<bool>(&iterator->second);
  if (boolean == nullptr) {
    return false;
  }
  *value = *boolean;
  return true;
}

int ToInt(double value) {
  return static_cast<int>(std::lround(value));
}

}  // namespace

// static
void ScreenCastWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<ScreenCastWindowsPlugin>(registrar);
  ScreenCastWindowsPlugin* plugin_pointer = plugin.get();
  channel->SetMethodCallHandler(
      [plugin_pointer](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  plugin->AttachChannel(std::move(channel));
  registrar->AddPlugin(std::move(plugin));
}

void ScreenCastWindowsPlugin::AttachChannel(
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel) {
  channel_ = std::move(channel);
}

ScreenCastWindowsPlugin::ScreenCastWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar), view_(std::make_unique<NativeVideoView>()) {
  if (view_ != nullptr) {
    view_->SetInputEventHandler(
        [this](const InputEvent& event) { SendInputEvent(event); });
    // Interactive resize finished: Dart re-measures the letterbox content rect.
    view_->SetResizeHandler([this]() {
      if (channel_) {
        channel_->InvokeMethod("windowResized",
                               std::make_unique<flutter::EncodableValue>());
      }
    });
    // The video window's close button only hides it (the session keeps
    // running). Dart brings the controller UI back so the window can be
    // reopened from there.
    view_->SetVisibilityHandler([this](bool visible) {
      if (channel_) {
        channel_->InvokeMethod(
            "videoVisibilityChanged",
            std::make_unique<flutter::EncodableValue>(visible));
      }
    });
    // The synchronous D3D11VA bridge needs the overlay's renderer.
    SetBridgeVideoView(view_.get());
  }
  if (registrar_ != nullptr) {
    top_level_proc_delegate_id_ =
        registrar_->RegisterTopLevelWindowProcDelegate(
            [this](HWND hwnd, UINT message, WPARAM wparam,
                   LPARAM lparam) -> std::optional<LRESULT> {
              return HandleTopLevelMessage(hwnd, message, wparam, lparam);
            });
  }
}

std::optional<LRESULT> ScreenCastWindowsPlugin::HandleTopLevelMessage(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  (void)wparam;
  if (message == TrayIcon::kCallbackMessage) {
    HandleTrayCallback(lparam);
    return 0;
  }
  if (message == WM_CLOSE && !quit_requested_) {
    // Closing the Flutter window minimizes to the tray; the capture session and
    // the independent video window keep running. "退出" in the tray menu is the
    // only real exit.
    if (hwnd != nullptr) {
      ShowWindow(hwnd, SW_HIDE);
    }
    tray_.Install(hwnd);
    UpdateTrayStatus();
    return 0;
  }
  return std::nullopt;
}

HWND ScreenCastWindowsPlugin::FlutterRootWindow() const {
  HWND view = FlutterViewWindow();
  return view == nullptr ? nullptr : GetAncestor(view, GA_ROOT);
}

void ScreenCastWindowsPlugin::ShowMainWindow() {
  HWND root = FlutterRootWindow();
  if (root == nullptr) {
    return;
  }
  ShowWindow(root, SW_SHOW);
  SetForegroundWindow(root);
}

void ScreenCastWindowsPlugin::ShowVideoWindow() {
  if (view_ != nullptr && view_->created()) {
    view_->Show();
  }
}

void ScreenCastWindowsPlugin::Quit() {
  quit_requested_ = true;
  tray_.Remove();
  HWND root = FlutterRootWindow();
  if (root != nullptr) {
    DestroyWindow(root);
  }
}

void ScreenCastWindowsPlugin::UpdateTrayStatus() {
  const bool connected = status_connected_;
  tray_.SetConnected(connected);
  std::wstring tooltip;
  if (!connected) {
    tooltip = L"未连接";
  } else {
    wchar_t buffer[160] = {};
    const int decode_fps = status_fps_;
    const int present_fps = view_ != nullptr ? view_->present_fps() : 0;
    if (status_width_ > 0 && status_height_ > 0 && decode_fps > 0) {
      swprintf_s(buffer, ARRAYSIZE(buffer),
                 L"已连接 · %d×%d · 解码 %dfps · 呈现 %dfps", status_width_,
                 status_height_, decode_fps, present_fps);
    } else if (status_width_ > 0 && status_height_ > 0) {
      swprintf_s(buffer, ARRAYSIZE(buffer), L"已连接 · %d×%d", status_width_,
                 status_height_);
    } else {
      swprintf_s(buffer, ARRAYSIZE(buffer), L"已连接");
    }
    tooltip = buffer;
  }
  tray_.SetTooltip(tooltip);
}

void ScreenCastWindowsPlugin::HandleTrayCallback(LPARAM lparam) {
  switch (LOWORD(lparam)) {
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowTrayMenu();
      break;
    case WM_LBUTTONDBLCLK:
      ShowMainWindow();
      break;
    default:
      break;
  }
}

void ScreenCastWindowsPlugin::ShowTrayMenu() {
  HWND root = FlutterRootWindow();
  if (root == nullptr) {
    return;
  }
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  AppendMenuW(menu, MF_STRING, 1, L"显示主窗口");
  AppendMenuW(menu, MF_STRING, 2, L"显示视频窗口");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 3, L"退出");

  POINT cursor = {};
  GetCursorPos(&cursor);
  // Required so the popup closes when the user clicks elsewhere.
  SetForegroundWindow(root);
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, cursor.x, cursor.y,
      0, root, nullptr);
  DestroyMenu(menu);

  switch (command) {
    case 1:
      ShowMainWindow();
      break;
    case 2:
      ShowVideoWindow();
      break;
    case 3:
      Quit();
      break;
    default:
      break;
  }
}

void ScreenCastWindowsPlugin::SendInputEvent(const InputEvent& event) {
  if (!channel_) {
    return;
  }
  flutter::EncodableMap arguments;
  arguments[flutter::EncodableValue("type")] =
      flutter::EncodableValue(event.type);
  arguments[flutter::EncodableValue("x")] =
      flutter::EncodableValue(static_cast<double>(event.normalized_x));
  arguments[flutter::EncodableValue("y")] =
      flutter::EncodableValue(static_cast<double>(event.normalized_y));
  arguments[flutter::EncodableValue("keyCode")] =
      flutter::EncodableValue(event.key_code);
  arguments[flutter::EncodableValue("wheelDelta")] =
      flutter::EncodableValue(event.wheel_delta);
  channel_->InvokeMethod(
      "controlEvent",
      std::make_unique<flutter::EncodableValue>(arguments));
}

ScreenCastWindowsPlugin::~ScreenCastWindowsPlugin() {
  tray_.Remove();
  if (registrar_ != nullptr && top_level_proc_delegate_id_ != 0) {
    registrar_->UnregisterTopLevelWindowProcDelegate(
        top_level_proc_delegate_id_);
    top_level_proc_delegate_id_ = 0;
  }
  if (view_) {
    SetBridgeVideoView(nullptr);
    view_->Dispose();
  }
}

HWND ScreenCastWindowsPlugin::FlutterViewWindow() const {
  if (registrar_ == nullptr) {
    return nullptr;
  }
  flutter::FlutterView* view = registrar_->GetView();
  return view == nullptr ? nullptr : view->GetNativeWindow();
}

void ScreenCastWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();
  const auto* arguments =
      std::get_if<flutter::EncodableMap>(method_call.arguments());

  if (method == "create") {
    HWND flutter_view = FlutterViewWindow();
    if (flutter_view == nullptr) {
      result->Error("NO_FLUTTER_VIEW", "Flutter view HWND is unavailable.");
      return;
    }
    HWND owner = GetAncestor(flutter_view, GA_ROOT);
    if (owner == nullptr) {
      result->Error("NO_TOP_LEVEL_WINDOW",
                    "Flutter top-level window HWND is unavailable.");
      return;
    }
    // Independent top-level video window; the Flutter window only supplies the
    // monitor it is centered on.
    if (!view_ || !view_->Create(owner, flutter_view)) {
      result->Error("CREATE_FAILED",
                    "Could not create the native video window.");
      return;
    }
    view_->Show();
    // Keep a tray icon for the whole session so the app can be restored after
    // the Flutter window is closed.
    tray_.Install(owner);
    UpdateTrayStatus();

    flutter::EncodableMap response;
    response[flutter::EncodableValue("d3d11")] =
        flutter::EncodableValue(view_->d3d_ready());
    result->Success(flutter::EncodableValue(response));
    return;
  }

  if (method == "setBounds") {
    // Kept for wire compatibility with older Dart builds: the video window is a
    // free-floating top-level window now, so only visibility is honoured.
    if (view_ == nullptr || !view_->created()) {
      result->Error("NOT_CREATED", "Call create before setBounds.");
      return;
    }
    if (arguments == nullptr) {
      result->Error("INVALID_ARGUMENTS", "setBounds requires a map.");
      return;
    }
    bool visible = true;
    ReadBool(*arguments, "visible", &visible);
    if (visible) {
      view_->Show();
    } else {
      view_->Hide();
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "showVideoWindow") {
    if (view_ == nullptr || !view_->created()) {
      result->Error("NOT_CREATED", "Call create before showVideoWindow.");
      return;
    }
    view_->Show();
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "showMainWindow") {
    // Used by LAN auto-connect to surface errors (e.g. a PSK mismatch) even
    // when the user closed the Flutter window to the tray.
    ShowMainWindow();
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "updateStatus") {
    // Tray icon + tooltip reflect the connection state pushed by Dart.
    if (arguments != nullptr) {
      bool connected = false;
      if (ReadBool(*arguments, "connected", &connected)) {
        status_connected_ = connected;
      }
      double width = 0;
      double height = 0;
      double fps = 0;
      status_width_ =
          ReadNumber(*arguments, "width", &width) ? ToInt(width) : 0;
      status_height_ =
          ReadNumber(*arguments, "height", &height) ? ToInt(height) : 0;
      status_fps_ = ReadNumber(*arguments, "fps", &fps) ? ToInt(fps) : 0;
    }
    tray_.Install(FlutterRootWindow());
    UpdateTrayStatus();
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "setVisible") {
    if (view_ == nullptr || !view_->created()) {
      result->Error("NOT_CREATED", "Call create before setVisible.");
      return;
    }
    if (arguments == nullptr) {
      result->Error("INVALID_ARGUMENTS", "setVisible requires a map.");
      return;
    }
    bool visible = true;
    if (!ReadBool(*arguments, "visible", &visible)) {
      result->Error("INVALID_ARGUMENTS", "visible must be a bool.");
      return;
    }
    if (visible) {
      view_->Show();
    } else {
      view_->Hide();
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "setInputEnabled") {
    if (view_ == nullptr) {
      result->Error("NOT_CREATED", "The native view is unavailable.");
      return;
    }
    if (arguments == nullptr) {
      result->Error("INVALID_ARGUMENTS", "setInputEnabled requires a map.");
      return;
    }
    bool enabled = false;
    if (!ReadBool(*arguments, "enabled", &enabled)) {
      result->Error("INVALID_ARGUMENTS", "enabled must be a bool.");
      return;
    }
    // Allowed before "create": Dart turns input on as soon as the control socket
    // connects, which can happen before the first overlay layout pass.
    view_->SetInputEnabled(enabled);
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "setContentRect") {
    if (view_ == nullptr || !view_->created()) {
      result->Error("NOT_CREATED", "Call create before setContentRect.");
      return;
    }
    if (arguments == nullptr) {
      result->Error("INVALID_ARGUMENTS", "setContentRect requires a map.");
      return;
    }
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;
    if (!ReadNumber(*arguments, "x", &x) || !ReadNumber(*arguments, "y", &y) ||
        !ReadNumber(*arguments, "width", &width) ||
        !ReadNumber(*arguments, "height", &height) || width <= 0 ||
        height <= 0) {
      result->Error("INVALID_ARGUMENTS",
                    "x/y/width/height must describe a positive rect.");
      return;
    }
    // Crops the encoder's letterbox bars and fits the window to the content
    // aspect ratio (once, unless the user already resized the window).
    view_->SetContentRect(static_cast<float>(x), static_cast<float>(y),
                          static_cast<float>(width),
                          static_cast<float>(height));
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "configureFrame") {
    if (view_ == nullptr || !view_->created()) {
      result->Error("NOT_CREATED", "Call create before configureFrame.");
      return;
    }
    if (arguments == nullptr) {
      result->Error("INVALID_ARGUMENTS", "configureFrame requires a map.");
      return;
    }

    double width = 0;
    double height = 0;
    if (!ReadNumber(*arguments, "width", &width) ||
        !ReadNumber(*arguments, "height", &height) ||
        width <= 0 || height <= 0) {
      result->Error("INVALID_ARGUMENTS",
                    "width and height must be positive numbers.");
      return;
    }

    Nv12UploadMapping mappings[kNv12UploadTextureCount];
    std::string error;
    if (!view_->ConfigureVideoFrame(
            static_cast<UINT>(ToInt(width)), static_cast<UINT>(ToInt(height)),
            mappings, &error)) {
      result->Error("FRAME_CONFIGURATION_FAILED", error.empty()
                                                     ? "Could not configure NV12 upload."
                                                     : error);
      return;
    }

    // Both staging textures are mapped up front; Dart rotates between them.
    flutter::EncodableList targets;
    for (int index = 0; index < kNv12UploadTextureCount; ++index) {
      flutter::EncodableMap target;
      target[flutter::EncodableValue("index")] = flutter::EncodableValue(index);
      target[flutter::EncodableValue("pointer")] = flutter::EncodableValue(
          static_cast<int64_t>(mappings[index].data));
      target[flutter::EncodableValue("rowPitch")] = flutter::EncodableValue(
          static_cast<int64_t>(mappings[index].row_pitch));
      targets.emplace_back(flutter::EncodableValue(target));
    }

    flutter::EncodableMap response;
    response[flutter::EncodableValue("targets")] =
        flutter::EncodableValue(targets);
    response[flutter::EncodableValue("width")] =
        flutter::EncodableValue(static_cast<int64_t>(ToInt(width)));
    response[flutter::EncodableValue("height")] =
        flutter::EncodableValue(static_cast<int64_t>(ToInt(height)));
    result->Success(flutter::EncodableValue(response));
    return;
  }

  if (method == "presentFrame") {
    if (view_ == nullptr || !view_->created()) {
      result->Error("NOT_CREATED", "Call create before presentFrame.");
      return;
    }
    if (arguments == nullptr) {
      result->Error("INVALID_ARGUMENTS", "presentFrame requires a map.");
      return;
    }

    // Dart picks one of the two staging textures; the buffer it just filled is
    // identified by index rather than by pointer, because the pointer changes
    // on every remap.
    double index = -1;
    if (!ReadNumber(*arguments, "index", &index) || index < 0 ||
        index >= kNv12UploadTextureCount) {
      result->Error("INVALID_ARGUMENTS",
                    "index must be 0 or 1 for the double-buffered upload.");
      return;
    }

    Nv12UploadMapping mapping;
    std::string error;
    if (!view_->PresentVideoFrame(ToInt(index), &mapping, &error)) {
      result->Error("FRAME_PRESENT_FAILED",
                    error.empty() ? "Could not present NV12 frame." : error);
      return;
    }

    flutter::EncodableMap response;
    response[flutter::EncodableValue("index")] =
        flutter::EncodableValue(ToInt(index));
    response[flutter::EncodableValue("pointer")] = flutter::EncodableValue(
        static_cast<int64_t>(mapping.data));
    response[flutter::EncodableValue("rowPitch")] =
        flutter::EncodableValue(static_cast<int64_t>(mapping.row_pitch));
    response[flutter::EncodableValue("width")] = flutter::EncodableValue(
        static_cast<int64_t>(view_->video_frame_width()));
    response[flutter::EncodableValue("height")] = flutter::EncodableValue(
        static_cast<int64_t>(view_->video_frame_height()));
    result->Success(flutter::EncodableValue(response));
    return;
  }

  if (method == "getStatus") {
    flutter::EncodableMap response;
    const bool created = view_ != nullptr && view_->created();
    response[flutter::EncodableValue("created")] =
        flutter::EncodableValue(created);
    response[flutter::EncodableValue("d3d11")] =
        flutter::EncodableValue(view_ != nullptr && view_->d3d_ready());
    response[flutter::EncodableValue("hasFrame")] =
        flutter::EncodableValue(view_ != nullptr && view_->has_video_frame());
    response[flutter::EncodableValue("frameWidth")] = flutter::EncodableValue(
        static_cast<int64_t>(view_ != nullptr ? view_->video_frame_width() : 0));
    response[flutter::EncodableValue("frameHeight")] = flutter::EncodableValue(
        static_cast<int64_t>(view_ != nullptr ? view_->video_frame_height() : 0));
    response[flutter::EncodableValue("displayedIndex")] =
        flutter::EncodableValue(
            view_ != nullptr ? view_->displayed_texture_index() : -1);
    response[flutter::EncodableValue("presentFps")] = flutter::EncodableValue(
        static_cast<int64_t>(view_ != nullptr ? view_->present_fps() : 0));
    response[flutter::EncodableValue("lastError")] = flutter::EncodableValue(
        view_ != nullptr ? view_->last_error() : std::string());
    result->Success(flutter::EncodableValue(response));
    return;
  }

  if (method == "dispose") {
    if (view_) {
      view_->Dispose();
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  result->NotImplemented();
}

}  // namespace screen_cast_windows

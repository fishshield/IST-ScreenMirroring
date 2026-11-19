#ifndef FLUTTER_PLUGIN_SCREEN_CAST_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_SCREEN_CAST_WINDOWS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <optional>
#include <string>

#include "native_video_view.h"
#include "tray_icon.h"

namespace screen_cast_windows {

class ScreenCastWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar);

  explicit ScreenCastWindowsPlugin(
      flutter::PluginRegistrarWindows* registrar);

  ~ScreenCastWindowsPlugin() override;

  ScreenCastWindowsPlugin(const ScreenCastWindowsPlugin&) = delete;
  ScreenCastWindowsPlugin& operator=(const ScreenCastWindowsPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Takes ownership of the method channel so the plugin can push captured
  // input events to Dart through the same channel Dart calls into.
  void AttachChannel(
      std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel);

 private:
  HWND FlutterViewWindow() const;
  HWND FlutterRootWindow() const;
  void SendInputEvent(const InputEvent& event);
  std::optional<LRESULT> HandleTopLevelMessage(HWND hwnd, UINT message,
                                               WPARAM wparam, LPARAM lparam);
  void HandleTrayCallback(LPARAM lparam);
  void ShowTrayMenu();
  void ShowMainWindow();
  void ShowVideoWindow();
  void Quit();
  void UpdateTrayStatus();

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<NativeVideoView> view_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  int top_level_proc_delegate_id_ = 0;

  TrayIcon tray_;
  bool quit_requested_ = false;
  bool status_connected_ = false;
  int status_width_ = 0;
  int status_height_ = 0;
  int status_fps_ = 0;
};

}  // namespace screen_cast_windows

#endif  // FLUTTER_PLUGIN_SCREEN_CAST_WINDOWS_PLUGIN_H_

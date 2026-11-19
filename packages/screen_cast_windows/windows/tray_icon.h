#ifndef SCREEN_CAST_WINDOWS_TRAY_ICON_H_
#define SCREEN_CAST_WINDOWS_TRAY_ICON_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <shellapi.h>

#include <string>

namespace screen_cast_windows {

// System-tray presence for the demo app.
//
// The tray icon is the app's "still running" affordance: closing the Flutter
// window minimizes to the tray and the capture session keeps running. The icon
// itself is drawn at runtime (green = connected, grey = idle) so the build does
// not need image assets.
class TrayIcon {
 public:
  // Callback message delivered to the owner window; the lower word of lParam is
  // a mouse message (WM_RBUTTONUP, WM_LBUTTONDBLCLK, ...).
  static constexpr UINT kCallbackMessage = WM_APP + 0x51;

  TrayIcon();
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // Adds the icon to the taskbar notification area.
  bool Install(HWND owner);
  void Remove();
  bool installed() const { return installed_; }

  // Swaps the icon and re-applies the tooltip text.
  void SetConnected(bool connected);
  void SetTooltip(const std::wstring& text);

 private:
  static HICON CreateStatusIcon(COLORREF fill, COLORREF ring);
  void Update();

  HWND owner_ = nullptr;
  NOTIFYICONDATAW data_ = {};
  HICON connected_icon_ = nullptr;
  HICON idle_icon_ = nullptr;
  bool installed_ = false;
  bool connected_ = false;
  std::wstring tooltip_ = L"未连接";
};

}  // namespace screen_cast_windows

#endif  // SCREEN_CAST_WINDOWS_TRAY_ICON_H_

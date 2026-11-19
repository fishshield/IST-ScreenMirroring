#include "native_video_view.h"

#include <algorithm>
#include <mutex>

#include <windowsx.h>

namespace screen_cast_windows {

namespace {
constexpr wchar_t kWindowClassName[] = L"ScreenCastVideoWindow";
constexpr wchar_t kWindowTitle[] = L"Screen Cast 视频";
std::once_flag g_register_once;
bool g_registered = false;

// Window sizing policy. Values are logical pixels and get scaled by the DPI of
// the monitor the window is created on.
constexpr int kInitialLandscapeWidth = 640;
constexpr int kInitialLandscapeHeight = 360;
constexpr int kInitialPortraitWidth = 360;
constexpr int kInitialPortraitHeight = 640;
constexpr int kCaptionHeight = 40;   // custom title bar with window buttons
constexpr int kCaptionButtonWidth = 46;
constexpr int kResizeBorder = 8;     // resize grip thickness
constexpr int kMinimumWidth = 240;
constexpr int kMinimumHeight = 135;

// Transitions. Windows does not animate a WS_POPUP/WS_THICKFRAME window with a
// custom caption, so show/hide use a DWM-style fade and the fullscreen toggle
// tweens the window rect for ~180 ms.
constexpr UINT_PTR kRectAnimationTimerId = 0x51C1;
constexpr int kRectAnimationFrameMs = 15;
constexpr int kFullscreenAnimationMs = 180;
constexpr int kShowAnimationMs = 160;
constexpr int kHideAnimationMs = 130;

int DpiForHwnd(HWND hwnd) {
  HDC dc = GetDC(hwnd);
  if (dc == nullptr) {
    return 96;
  }
  const int dpi = GetDeviceCaps(dc, LOGPIXELSX);
  ReleaseDC(hwnd, dc);
  return dpi > 0 ? dpi : 96;
}

int ScaledValue(int value, int dpi) {
  return MulDiv(value, dpi, 96);
}

}  // namespace

NativeVideoView::NativeVideoView() = default;

NativeVideoView::~NativeVideoView() {
  Dispose();
}

bool NativeVideoView::RegisterWindowClass() {
  std::call_once(g_register_once, []() {
    WNDCLASSEXW window_class = {};
    window_class.cbSize = sizeof(window_class);
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.lpfnWndProc = &NativeVideoView::WindowProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;

    if (RegisterClassExW(&window_class) != 0) {
      g_registered = true;
      return;
    }
    g_registered = GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
  });
  return g_registered;
}

bool NativeVideoView::Create(HWND owner, HWND flutter_view) {
  if (hwnd_ != nullptr) {
    return true;
  }
  if (!RegisterWindowClass()) {
    return false;
  }

  owner_ = owner;
  flutter_view_ = flutter_view;
  fallback_brush_ = CreateSolidBrush(RGB(12, 72, 64));

  // Independent top-level window: no owner, no parent. WS_EX_APPWINDOW puts it
  // in the taskbar so minimize/restore works like a normal app window.
  // WS_POPUP | WS_THICKFRAME gives a resizable border that WM_NCCALCSIZE and
  // WM_NCHITTEST then hide/re-create by hand.
  const int dpi = flutter_view != nullptr ? DpiForHwnd(flutter_view) : 96;
  const int client_width = ScaledValue(initial_width_, dpi);
  const int client_height = ScaledValue(initial_height_, dpi);
  const int width = client_width;
  const int height = client_height + ScaledValue(kCaptionHeight, dpi);
  int left = CW_USEDEFAULT;
  int top = CW_USEDEFAULT;
  if (flutter_view != nullptr) {
    RECT host = {};
    if (GetWindowRect(flutter_view, &host)) {
      left = host.left + ((host.right - host.left) - width) / 2;
      top = host.top + ((host.bottom - host.top) - height) / 2;
    }
  }

  hwnd_ = CreateWindowExW(
      WS_EX_APPWINDOW, kWindowClassName, kWindowTitle,
      WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX, left, top, width, height,
      nullptr, nullptr, GetModuleHandleW(nullptr), this);
  if (hwnd_ == nullptr) {
    if (fallback_brush_ != nullptr) {
      DeleteObject(fallback_brush_);
      fallback_brush_ = nullptr;
    }
    return false;
  }

  // The runner registers the app icon on the main window class. This is a
  // separate top-level window, so without copying it the taskbar and Alt+Tab
  // show the generic/default (Flutter) icon instead of the app's.
  const HWND icon_source = owner_ != nullptr ? owner_ : flutter_view_;
  if (icon_source != nullptr) {
    HICON big_icon = reinterpret_cast<HICON>(
        SendMessageW(icon_source, WM_GETICON, ICON_BIG, 0));
    if (big_icon == nullptr) {
      big_icon =
          reinterpret_cast<HICON>(GetClassLongPtrW(icon_source, GCLP_HICON));
    }
    HICON small_icon = reinterpret_cast<HICON>(
        SendMessageW(icon_source, WM_GETICON, ICON_SMALL, 0));
    if (small_icon == nullptr) {
      small_icon = big_icon;
    }
    if (big_icon != nullptr) {
      SendMessageW(hwnd_, WM_SETICON, ICON_BIG,
                   reinterpret_cast<LPARAM>(big_icon));
    }
    if (small_icon != nullptr) {
      SendMessageW(hwnd_, WM_SETICON, ICON_SMALL,
                   reinterpret_cast<LPARAM>(small_icon));
    }
  }

  // If D3D11 cannot initialize, WM_PAINT fills the window with a solid color
  // using GDI so the window still behaves predictably on a broken GPU driver.
  renderer_.Initialize(hwnd_);

  // Custom title bar font (the caption strip is non-client, so GDI owns it).
  caption_font_ = CreateFontW(-MulDiv(12, dpi, 96), 0, 0, 0, FW_SEMIBOLD, FALSE,
                              FALSE, FALSE, DEFAULT_CHARSET,
                              OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                              CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS,
                              L"Microsoft YaHei UI");
  RedrawCaption();
  return true;
}

void NativeVideoView::Dispose() {
  if (hwnd_ != nullptr) {
    StopRectAnimation();
    if (GetCapture() == hwnd_) {
      ReleaseCapture();
    }
    if (IsWindow(hwnd_)) {
      DestroyWindow(hwnd_);
    }
    hwnd_ = nullptr;
  }
  owner_ = nullptr;
  flutter_view_ = nullptr;
  fullscreen_ = false;
  shown_by_user_ = false;
  user_resized_ = false;
  has_content_rect_ = false;
  input_enabled_ = false;
  input_handler_ = nullptr;
  resize_handler_ = nullptr;
  visibility_handler_ = nullptr;
  renderer_.Shutdown();
  if (caption_font_ != nullptr) {
    DeleteObject(caption_font_);
    caption_font_ = nullptr;
  }
  if (fallback_brush_ != nullptr) {
    DeleteObject(fallback_brush_);
    fallback_brush_ = nullptr;
  }
}

void NativeVideoView::Show() {
  if (hwnd_ == nullptr) {
    return;
  }
  shown_by_user_ = true;
  // Fit the frame while it is still hidden, so the fade-in does not jump.
  ApplyContentAspect();
  if (!AnimateWindow(hwnd_, kShowAnimationMs, AW_BLEND | AW_ACTIVATE)) {
    ShowWindow(hwnd_, SW_SHOW);
  }
  SetForegroundWindow(hwnd_);
  if (input_enabled_) {
    SetFocus(hwnd_);
  }
  RedrawCaption();
  InvalidateRect(hwnd_, nullptr, FALSE);
  if (visibility_handler_ != nullptr) {
    visibility_handler_(true);
  }
}

void NativeVideoView::Hide() {
  if (hwnd_ == nullptr) {
    return;
  }
  shown_by_user_ = false;
  StopRectAnimation();
  if (!AnimateWindow(hwnd_, kHideAnimationMs, AW_HIDE | AW_BLEND)) {
    ShowWindow(hwnd_, SW_HIDE);
  }
  if (visibility_handler_ != nullptr) {
    visibility_handler_(false);
  }
}

void NativeVideoView::SetVisibilityHandler(
    std::function<void(bool)> handler) {
  visibility_handler_ = std::move(handler);
}

bool NativeVideoView::visible() const {
  return hwnd_ != nullptr && IsWindowVisible(hwnd_) != FALSE;
}

int NativeVideoView::ScaleForDpi(int value) const {
  const int dpi = hwnd_ != nullptr ? DpiForHwnd(hwnd_)
                                   : (flutter_view_ != nullptr
                                          ? DpiForHwnd(flutter_view_)
                                          : 96);
  return ScaledValue(value, dpi);
}

int NativeVideoView::CaptionHeight() const {
  if (fullscreen_ || hwnd_ == nullptr) {
    return 0;
  }
  return ScaleForDpi(kCaptionHeight);
}

RECT NativeVideoView::CaptionRect() const {
  RECT window = {};
  GetWindowRect(hwnd_, &window);
  RECT caption = {};
  caption.left = window.left;
  caption.top = window.top;
  caption.right = window.right;
  caption.bottom = window.top + CaptionHeight();
  return caption;
}

RECT NativeVideoView::CaptionButtonRect(int index) const {
  RECT window = {};
  GetWindowRect(hwnd_, &window);
  const int caption = CaptionHeight();
  const int button_width = ScaleForDpi(kCaptionButtonWidth);
  RECT button = {};
  button.right = window.right - (2 - index) * button_width;
  button.left = button.right - button_width;
  button.top = window.top;
  button.bottom = window.top + caption;
  return button;
}

void NativeVideoView::PaintCaption(HDC dc) {
  if (hwnd_ == nullptr) {
    return;
  }
  const int caption = CaptionHeight();
  if (caption <= 0) {
    return;
  }

  RECT window = {};
  GetWindowRect(hwnd_, &window);
  RECT strip = {};
  strip.left = 0;
  strip.top = 0;
  strip.right = window.right - window.left;
  strip.bottom = caption;

  HBRUSH background = CreateSolidBrush(RGB(16, 26, 34));
  FillRect(dc, &strip, background);
  DeleteObject(background);

  // 1px separator between the caption and the video area.
  RECT line = strip;
  line.top = caption - 1;
  HBRUSH separator = CreateSolidBrush(RGB(42, 54, 68));
  FillRect(dc, &line, separator);
  DeleteObject(separator);

  const int button_width = ScaleForDpi(kCaptionButtonWidth);
  const bool active = GetForegroundWindow() == hwnd_;
  const COLORREF glyph_color = active ? RGB(226, 234, 242) : RGB(150, 162, 174);

  // Three flat buttons: minimize, fullscreen, close.
  HPEN pen = CreatePen(PS_SOLID, ScaleForDpi(1), glyph_color);
  HGDIOBJ old_pen = SelectObject(dc, pen);
  HGDIOBJ old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
  const int glyph = ScaleForDpi(5);
  for (int index = 0; index < 3; index++) {
    RECT button = {};
    button.right = strip.right - (2 - index) * button_width;
    button.left = button.right - button_width;
    button.top = 0;
    button.bottom = caption;
    const int center_x = (button.left + button.right) / 2;
    const int center_y = (button.top + button.bottom) / 2;
    switch (index) {
      case 0:  // minimize
        MoveToEx(dc, center_x - glyph, center_y, nullptr);
        LineTo(dc, center_x + glyph + 1, center_y);
        break;
      case 1:  // fullscreen / restore
        Rectangle(dc, center_x - glyph, center_y - glyph, center_x + glyph,
                  center_y + glyph);
        break;
      default:  // close
        MoveToEx(dc, center_x - glyph, center_y - glyph, nullptr);
        LineTo(dc, center_x + glyph + 1, center_y + glyph + 1);
        MoveToEx(dc, center_x - glyph, center_y + glyph, nullptr);
        LineTo(dc, center_x + glyph + 1, center_y - glyph - 1);
        break;
    }
  }
  SelectObject(dc, old_pen);
  SelectObject(dc, old_brush);
  DeleteObject(pen);

  // No caption text: the window is meant to look like the phone screen with
  // only the three control glyphs on the right.
}

void NativeVideoView::RedrawCaption() {
  if (hwnd_ == nullptr) {
    return;
  }
  RedrawWindow(hwnd_, nullptr, nullptr, RDW_FRAME | RDW_INVALIDATE);
}

void NativeVideoView::SetContentRect(float x, float y, float width,
                                     float height) {
  if (!(width > 0.0f) || !(height > 0.0f)) {
    return;
  }
  content_rect_[0] = x;
  content_rect_[1] = y;
  content_rect_[2] = width;
  content_rect_[3] = height;
  has_content_rect_ = true;
  renderer_.SetContentRect(x, y, width, height);
  ApplyContentAspect();
  if (hwnd_ != nullptr) {
    InvalidateRect(hwnd_, nullptr, FALSE);
  }
}

void NativeVideoView::ApplyContentAspect() {
  if (!has_content_rect_ || fullscreen_ || hwnd_ == nullptr ||
      IsZoomed(hwnd_) || IsIconic(hwnd_)) {
    return;
  }
  const float frame_width = static_cast<float>(renderer_.frame_width());
  const float frame_height = static_cast<float>(renderer_.frame_height());
  if (frame_width <= 0.0f || frame_height <= 0.0f) {
    return;
  }
  const float content_width = content_rect_[2] * frame_width;
  const float content_height = content_rect_[3] * frame_height;
  if (content_width <= 0.0f || content_height <= 0.0f) {
    return;
  }
  const float aspect = content_width / content_height;

  // Keep the current client height and derive the width from the content
  // aspect, so a rotation re-fits the window without jumping in size.
  RECT client = {};
  GetClientRect(hwnd_, &client);
  int client_height = client.bottom - client.top;
  if (client_height < ScaleForDpi(kMinimumHeight)) {
    client_height = ScaleForDpi(640);
  }
  int client_width = static_cast<int>(client_height * aspect + 0.5f);
  if (client_width < ScaleForDpi(kMinimumWidth)) {
    client_width = ScaleForDpi(kMinimumWidth);
  }
  // Keep the window inside the work area.
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  if (GetMonitorInfoW(MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST),
                      &monitor_info)) {
    const int max_width = monitor_info.rcWork.right - monitor_info.rcWork.left;
    const int max_height = monitor_info.rcWork.bottom - monitor_info.rcWork.top;
    if (client_width + ScaleForDpi(24) > max_width) {
      client_width = max_width - ScaleForDpi(24);
      client_height = static_cast<int>(client_width / aspect + 0.5f);
    }
    if (client_height + CaptionHeight() + ScaleForDpi(24) > max_height) {
      client_height = max_height - CaptionHeight() - ScaleForDpi(24);
      client_width = static_cast<int>(client_height * aspect + 0.5f);
    }
  }
  if (client_width < ScaleForDpi(kMinimumWidth)) {
    client_width = ScaleForDpi(kMinimumWidth);
  }
  if (client_height < ScaleForDpi(kMinimumHeight)) {
    client_height = ScaleForDpi(kMinimumHeight);
  }

  RECT current = {};
  if (!GetWindowRect(hwnd_, &current)) {
    return;
  }
  const int caption = CaptionHeight();
  const int total_width = client_width;
  const int total_height = client_height + caption;
  const int center_x = (current.left + current.right) / 2;
  const int center_y = (current.top + current.bottom) / 2;
  if ((current.right - current.left) == total_width &&
      (current.bottom - current.top) == total_height) {
    return;
  }
  SetWindowPos(hwnd_, HWND_TOP, center_x - total_width / 2,
               center_y - total_height / 2, total_width, total_height,
               SWP_NOACTIVATE | SWP_FRAMECHANGED);
  RedrawCaption();
}

void NativeVideoView::UpdateInitialAspect(UINT video_width,
                                          UINT video_height) {
  if (applied_initial_aspect_ || hwnd_ == nullptr || video_width == 0 ||
      video_height == 0 || video_width == video_height) {
    applied_initial_aspect_ = true;
    return;
  }
  applied_initial_aspect_ = true;

  // Portrait content gets a portrait window; landscape keeps the default.
  const bool portrait = video_height > video_width;
  const int width = portrait ? kInitialPortraitWidth : kInitialLandscapeWidth;
  const int height = portrait ? kInitialPortraitHeight : kInitialLandscapeHeight;
  if (width == initial_width_ && height == initial_height_) {
    return;
  }
  initial_width_ = width;
  initial_height_ = height;
  if (fullscreen_ || IsZoomed(hwnd_) || has_content_rect_) {
    // The content rect (letterbox cropping) is the better source of truth once
    // it is known; skip the coarse video-aspect resize in that case.
    return;
  }

  RECT current = {};
  if (!GetWindowRect(hwnd_, &current)) {
    return;
  }
  const int scaled_width = ScaleForDpi(initial_width_);
  const int scaled_height = ScaleForDpi(initial_height_) + CaptionHeight();
  const int center_x = (current.left + current.right) / 2;
  const int center_y = (current.top + current.bottom) / 2;
  SetWindowPos(hwnd_, HWND_TOP, center_x - scaled_width / 2,
               center_y - scaled_height / 2, scaled_width, scaled_height,
               SWP_NOACTIVATE | SWP_FRAMECHANGED);
  RedrawCaption();
}

bool NativeVideoView::ConfigureVideoFrame(UINT width, UINT height,
                                          Nv12UploadMapping* mappings,
                                          std::string* error) {
  if (hwnd_ == nullptr || !renderer_.ready()) {
    if (error != nullptr) {
      *error = "Native D3D11 video window is not initialized.";
    }
    return false;
  }
  UpdateInitialAspect(width, height);
  return renderer_.ConfigureVideoFrame(width, height, mappings, error);
}

bool NativeVideoView::PresentVideoFrame(int index, Nv12UploadMapping* mapping,
                                        std::string* error) {
  if (hwnd_ == nullptr || !renderer_.ready()) {
    if (error != nullptr) {
      *error = "Native D3D11 video window is not initialized.";
    }
    return false;
  }
  if (!renderer_.PresentVideoFrame(index, mapping, error)) {
    return false;
  }
  InvalidateRect(hwnd_, nullptr, FALSE);
  return true;
}

int NativeVideoView::CopyHardwareFrame(void* texture, intptr_t slice,
                                       UINT width, UINT height,
                                       std::string* error) {
  if (hwnd_ == nullptr || !renderer_.ready()) {
    if (error != nullptr) {
      *error = "Native D3D11 video window is not initialized.";
    }
    return D3D11Renderer::kHardwareCopyFailed;
  }
  UpdateInitialAspect(width, height);
  auto* decoded = static_cast<ID3D11Texture2D*>(texture);
  const D3D11Renderer::HardwareCopyResult result = renderer_.CopyHardwareFrame(
      decoded, static_cast<UINT>(slice), width, height, error);
  if (result == D3D11Renderer::kHardwareCopyOk) {
    // Let the message loop draw it; blocking here would stall the decode loop.
    InvalidateRect(hwnd_, nullptr, FALSE);
  }
  return result;
}

void NativeVideoView::ToggleFullscreen() {
  if (fullscreen_) {
    ExitFullscreen();
  } else {
    EnterFullscreen();
  }
}

void NativeVideoView::EnterFullscreen() {
  if (hwnd_ == nullptr || fullscreen_) {
    return;
  }
  if (!GetWindowRect(hwnd_, &restore_rect_)) {
    return;
  }
  restore_style_ = GetWindowLongPtrW(hwnd_, GWL_STYLE);

  // Drop the resize frame, keep it a top-level popup covering the monitor.
  // The flag/style change happens before the tween so the caption disappears
  // immediately and the client area grows with the animation.
  SetWindowLongPtrW(hwnd_, GWL_STYLE,
                    (restore_style_ & ~(WS_THICKFRAME | WS_CAPTION |
                                        WS_DLGFRAME | WS_BORDER)) | WS_POPUP);
  SetWindowPos(hwnd_, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE | SWP_NOOWNERZORDER);
  fullscreen_ = true;
  HMONITOR monitor = MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  if (GetMonitorInfoW(monitor, &info)) {
    AnimateRectTo(info.rcMonitor, kFullscreenAnimationMs);
  }
  RedrawCaption();
  InvalidateRect(hwnd_, nullptr, FALSE);
}

void NativeVideoView::ExitFullscreen() {
  if (hwnd_ == nullptr || !fullscreen_) {
    return;
  }
  fullscreen_ = false;
  SetWindowLongPtrW(hwnd_, GWL_STYLE, restore_style_);
  SetWindowPos(hwnd_, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE | SWP_NOOWNERZORDER);
  RedrawCaption();
  AnimateRectTo(restore_rect_, kFullscreenAnimationMs);
  InvalidateRect(hwnd_, nullptr, FALSE);
}

void NativeVideoView::AnimateRectTo(const RECT& target, int duration_ms) {
  if (hwnd_ == nullptr) {
    return;
  }
  RECT current = {};
  if (!GetWindowRect(hwnd_, &current)) {
    return;
  }
  anim_from_ = current;
  anim_to_ = target;
  anim_started_at_ = GetTickCount();
  anim_duration_ms_ = duration_ms;
  rect_animating_ = true;
  SetTimer(hwnd_, kRectAnimationTimerId, kRectAnimationFrameMs, nullptr);
}

void NativeVideoView::StopRectAnimation() {
  if (!rect_animating_) {
    return;
  }
  rect_animating_ = false;
  if (hwnd_ != nullptr) {
    KillTimer(hwnd_, kRectAnimationTimerId);
  }
}

LRESULT NativeVideoView::OnAnimationTimer() {
  if (!rect_animating_ || hwnd_ == nullptr) {
    return 0;
  }
  const DWORD elapsed = GetTickCount() - anim_started_at_;
  float t = anim_duration_ms_ > 0
                ? static_cast<float>(elapsed) / static_cast<float>(
                                                    anim_duration_ms_)
                : 1.0f;
  if (t > 1.0f) {
    t = 1.0f;
  }
  // Ease-out cubic: fast start, soft landing.
  const float eased = 1.0f - (1.0f - t) * (1.0f - t) * (1.0f - t);
  const auto lerp = [](int from, int to, float k) {
    return from + static_cast<int>(
                      static_cast<float>(to - from) * k +
                      (to >= from ? 0.5f : -0.5f));
  };
  const int left = lerp(anim_from_.left, anim_to_.left, eased);
  const int top = lerp(anim_from_.top, anim_to_.top, eased);
  const int right = lerp(anim_from_.right, anim_to_.right, eased);
  const int bottom = lerp(anim_from_.bottom, anim_to_.bottom, eased);
  SetWindowPos(hwnd_, nullptr, left, top, right - left, bottom - top,
               SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
  if (t >= 1.0f) {
    StopRectAnimation();
  }
  return 0;
}

LRESULT CALLBACK NativeVideoView::WindowProc(HWND hwnd, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create_struct = reinterpret_cast<CREATESTRUCTW*>(lparam);
    auto* self = static_cast<NativeVideoView*>(create_struct->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    return TRUE;
  }

  auto* self = reinterpret_cast<NativeVideoView*>(
      GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self != nullptr) {
    return self->HandleMessage(hwnd, message, wparam, lparam);
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT NativeVideoView::HitTest(LPARAM lparam) const {
  RECT window = {};
  GetWindowRect(hwnd_, &window);

  if (fullscreen_) {
    return HTCLIENT;
  }

  const POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  const int border = ScaleForDpi(kResizeBorder);
  const int caption_bottom = window.top + CaptionHeight();

  const bool on_left = point.x < window.left + border;
  const bool on_right = point.x >= window.right - border;
  const bool on_top = point.y < window.top + border;
  const bool on_bottom = point.y >= window.bottom - border;

  // Caption strip: window buttons win, then dragging, then the top resize edge.
  if (point.y < caption_bottom) {
    for (int index = 0; index < 3; index++) {
      const RECT button = CaptionButtonRect(index);
      if (point.x >= button.left && point.x < button.right &&
          point.y >= button.top && point.y < button.bottom) {
        return index == 0 ? HTMINBUTTON
                          : (index == 1 ? HTMAXBUTTON : HTCLOSE);
      }
    }
    if (!on_top) {
      return HTCAPTION;
    }
    if (on_left) {
      return HTTOPLEFT;
    }
    if (on_right) {
      return HTTOPRIGHT;
    }
    return HTTOP;
  }

  if (on_top && on_left) {
    return HTTOPLEFT;
  }
  if (on_top && on_right) {
    return HTTOPRIGHT;
  }
  if (on_bottom && on_left) {
    return HTBOTTOMLEFT;
  }
  if (on_bottom && on_right) {
    return HTBOTTOMRIGHT;
  }
  if (on_top) {
    return HTTOP;
  }
  if (on_bottom) {
    return HTBOTTOM;
  }
  if (on_left) {
    return HTLEFT;
  }
  if (on_right) {
    return HTRIGHT;
  }
  return HTCLIENT;
}

LRESULT NativeVideoView::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam) {
  switch (message) {
    case WM_TIMER:
      if (wparam == kRectAnimationTimerId) {
        return OnAnimationTimer();
      }
      return DefWindowProcW(hwnd, message, wparam, lparam);
    case WM_NCCALCSIZE:
      // Client area = window minus the custom caption strip. Everything else
      // (borders, rounded DWM frame) is removed so the video fills the window.
      if (wparam == TRUE) {
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        params->rgrc[0].top += CaptionHeight();
        return 0;
      }
      return DefWindowProcW(hwnd, message, wparam, lparam);
    case WM_NCPAINT: {
      HDC dc = GetWindowDC(hwnd);
      if (dc != nullptr) {
        PaintCaption(dc);
        ReleaseDC(hwnd, dc);
      }
      return 0;
    }
    case WM_NCACTIVATE:
      // Keep our own caption colours instead of the default non-client paint.
      RedrawCaption();
      return TRUE;
    case WM_NCHITTEST:
      return HitTest(lparam);
    case WM_NCLBUTTONDOWN:
      // Custom caption buttons (the window has no system frame).
      if (wparam == HTCLOSE) {
        Hide();
        return 0;
      }
      if (wparam == HTMINBUTTON) {
        ShowWindow(hwnd, SW_MINIMIZE);
        return 0;
      }
      if (wparam == HTMAXBUTTON) {
        ToggleFullscreen();
        return 0;
      }
      return DefWindowProcW(hwnd, message, wparam, lparam);
    case WM_NCLBUTTONDBLCLK:
      if (wparam == HTCAPTION) {
        ToggleFullscreen();
        return 0;
      }
      return DefWindowProcW(hwnd, message, wparam, lparam);
    case WM_ENTERSIZEMOVE:
      // Once the user moves or resizes the frame, stop auto-fitting it to the
      // content aspect ratio.
      user_resized_ = true;
      return 0;
    case WM_EXITSIZEMOVE:
      user_resized_ = true;
      // Interactive resize finished: let Dart re-measure the content rect if
      // the user changed the window geometry. Programmatic SetWindowPos calls
      // (fullscreen, initial placement, aspect fitting) never send this
      // message, so no feedback loop is possible.
      if (resize_handler_ != nullptr) {
        resize_handler_();
      }
      return 0;
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = ScaleForDpi(kMinimumWidth);
      info->ptMinTrackSize.y = ScaleForDpi(kMinimumHeight);
      return 0;
    }
    case WM_SIZING: {
      // Keep the video window proportional while dragging an edge: derive the
      // other dimension from the content aspect ratio.
      if (!has_content_rect_ || fullscreen_ || !renderer_.ready()) {
        return TRUE;
      }
      const float frame_width = static_cast<float>(renderer_.frame_width());
      const float frame_height = static_cast<float>(renderer_.frame_height());
      const float content_width = content_rect_[2] * frame_width;
      const float content_height = content_rect_[3] * frame_height;
      if (content_width <= 0.0f || content_height <= 0.0f) {
        return TRUE;
      }
      auto* rect = reinterpret_cast<RECT*>(lparam);
      int width = rect->right - rect->left;
      int height = rect->bottom - rect->top;
      if (wparam == WMSZ_LEFT || wparam == WMSZ_RIGHT ||
          wparam == WMSZ_TOPLEFT || wparam == WMSZ_TOPRIGHT ||
          wparam == WMSZ_BOTTOMLEFT || wparam == WMSZ_BOTTOMRIGHT) {
        height = static_cast<int>(
            static_cast<float>(width - 0) / (content_width / content_height) +
            0.5f);
        rect->bottom = rect->top + height;
      } else {
        width = static_cast<int>(
            static_cast<float>(height - CaptionHeight()) *
                (content_width / content_height) +
            0.5f);
        rect->right = rect->left + width;
      }
      return TRUE;
    }
    case WM_DPICHANGED: {
      const RECT* suggested = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(hwnd, nullptr, suggested->left, suggested->top,
                   suggested->right - suggested->left,
                   suggested->bottom - suggested->top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint = {};
      HDC device_context = BeginPaint(hwnd, &paint);
      if (renderer_.ready()) {
        renderer_.Render();
      } else {
        RECT client = {};
        GetClientRect(hwnd, &client);
        if (fallback_brush_ != nullptr) {
          FillRect(device_context, &client, fallback_brush_);
        }
      }
      EndPaint(hwnd, &paint);
      return 0;
    }
    case WM_SIZE: {
      const UINT width = LOWORD(lparam);
      const UINT height = HIWORD(lparam);
      if (width > 0 && height > 0) {
        if (!renderer_.ready()) {
          renderer_.Initialize(hwnd);
        }
        renderer_.Resize(width, height);
        renderer_.Render();
        RedrawCaption();
      }
      return 0;
    }
    case WM_LBUTTONDOWN:
      // Take keyboard focus so WM_KEYDOWN/UP reach this window; the existing
      // capture/normalization path is unchanged.
      SetFocus(hwnd);
      if (!input_enabled_) {
        return 0;
      }
      SetCapture(hwnd);
      EmitPointerEvent(1, lparam);
      return 0;
    case WM_MOUSEMOVE:
      if (input_enabled_) {
        EmitPointerEvent(2, lparam);
      }
      return 0;
    case WM_LBUTTONUP:
      if (!input_enabled_) {
        return 0;
      }
      EmitPointerEvent(3, lparam);
      if (GetCapture() == hwnd) {
        ReleaseCapture();
      }
      return 0;
    case WM_MOUSEWHEEL:
      if (input_enabled_) {
        EmitWheelEvent(wparam, lparam);
      }
      return 0;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
      // Window shortcuts win over remote key injection: F11 toggles
      // fullscreen, and Esc only leaves fullscreen instead of closing.
      if (wparam == VK_F11) {
        ToggleFullscreen();
        return 0;
      }
      if (fullscreen_ && wparam == VK_ESCAPE) {
        ExitFullscreen();
        return 0;
      }
      if (input_enabled_) {
        EmitKeyEvent(5, wparam);
      }
      return 0;
    case WM_KEYUP:
    case WM_SYSKEYUP:
      if (wparam == VK_F11 || (fullscreen_ && wparam == VK_ESCAPE)) {
        return 0;
      }
      if (input_enabled_) {
        EmitKeyEvent(6, wparam);
      }
      return 0;
    case WM_CLOSE:
      // Closing the video window must not end the capture session.
      Hide();
      return 0;
    case WM_DESTROY:
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
      return 0;
    default:
      return DefWindowProcW(hwnd, message, wparam, lparam);
  }
}

void NativeVideoView::SetInputEnabled(bool enabled) {
  if (input_enabled_ == enabled) {
    return;
  }
  input_enabled_ = enabled;
  if (!enabled) {
    if (GetCapture() == hwnd_) {
      ReleaseCapture();
    }
    if (GetFocus() == hwnd_ && flutter_view_ != nullptr &&
        IsWindowVisible(flutter_view_)) {
      // Hand keyboard focus back to Flutter so text fields keep working.
      SetFocus(flutter_view_);
    }
  }
  if (hwnd_ != nullptr) {
    InvalidateRect(hwnd_, nullptr, FALSE);
  }
}

void NativeVideoView::SetInputEventHandler(InputEventHandler handler) {
  input_handler_ = std::move(handler);
}

void NativeVideoView::SetResizeHandler(std::function<void()> handler) {
  resize_handler_ = std::move(handler);
}

namespace {

float Clamp01(float value) {
  if (value < 0.0f) {
    return 0.0f;
  }
  if (value > 1.0f) {
    return 1.0f;
  }
  return value;
}

}  // namespace

RECT NativeVideoView::ContentRectInClient() const {
  RECT client = {};
  GetClientRect(hwnd_, &client);
  RECT content = client;
  const float frame_width = static_cast<float>(renderer_.frame_width());
  const float frame_height = static_cast<float>(renderer_.frame_height());
  const float content_width = content_rect_[2] * frame_width;
  const float content_height = content_rect_[3] * frame_height;
  if (content_width <= 0.0f || content_height <= 0.0f) {
    return content;
  }
  const float content_aspect = content_width / content_height;
  const float client_width = static_cast<float>(client.right - client.left);
  const float client_height = static_cast<float>(client.bottom - client.top);
  float dest_width = client_width;
  float dest_height = client_height;
  if (client_width / client_height > content_aspect) {
    dest_width = client_height * content_aspect;
  } else {
    dest_height = client_width / content_aspect;
  }
  content.left = static_cast<LONG>((client_width - dest_width) * 0.5f);
  content.top = static_cast<LONG>((client_height - dest_height) * 0.5f);
  content.right = content.left + static_cast<LONG>(dest_width);
  content.bottom = content.top + static_cast<LONG>(dest_height);
  return content;
}

void NativeVideoView::EmitPointerEvent(int type, LPARAM lparam) {
  if (input_handler_ == nullptr || hwnd_ == nullptr) {
    return;
  }
  RECT client = {};
  if (!GetClientRect(hwnd_, &client)) {
    return;
  }
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0) {
    return;
  }
  const int x = static_cast<short>(LOWORD(lparam));
  const int y = static_cast<short>(HIWORD(lparam));

  // The server expects normalized coordinates of the *whole video frame*: it
  // multiplies them by the encoder size and then removes the letterbox padding
  // (InputInjector: videoX = nx * videoWidth -> displayX).
  //
  // This window only shows the content sub-rect, so map the click through the
  // content viewport back into frame space: the visible content is
  // [content_rect_.x, +width] of the frame, and the window client shows exactly
  // that rect.
  const RECT content = ContentRectInClient();
  const float content_width =
      static_cast<float>(content.right - content.left);
  const float content_height =
      static_cast<float>(content.bottom - content.top);

  float normalized_x = Clamp01(static_cast<float>(x) / static_cast<float>(width));
  float normalized_y = Clamp01(static_cast<float>(y) / static_cast<float>(height));
  if (content_width > 0.0f && content_height > 0.0f && has_content_rect_) {
    const float within_content_x =
        Clamp01((static_cast<float>(x) - content.left) / content_width);
    const float within_content_y =
        Clamp01((static_cast<float>(y) - content.top) / content_height);
    normalized_x = content_rect_[0] + within_content_x * content_rect_[2];
    normalized_y = content_rect_[1] + within_content_y * content_rect_[3];
  }

  InputEvent event;
  event.type = type;
  event.normalized_x = normalized_x;
  event.normalized_y = normalized_y;
  input_handler_(event);
}

void NativeVideoView::EmitWheelEvent(WPARAM wparam, LPARAM lparam) {
  if (input_handler_ == nullptr || hwnd_ == nullptr) {
    return;
  }
  RECT client = {};
  if (!GetClientRect(hwnd_, &client)) {
    return;
  }
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0) {
    return;
  }
  POINT point = {static_cast<short>(LOWORD(lparam)),
                 static_cast<short>(HIWORD(lparam))};
  ScreenToClient(hwnd_, &point);

  // Windows: GET_WHEEL_DELTA_WPARAM returns a multiple of WHEEL_DELTA (120),
  // positive when the wheel rotates away from the user (scroll up). It is sent
  // unchanged; the verified Android side uses the same sign for AXIS_VSCROLL.
  const int windows_delta = GET_WHEEL_DELTA_WPARAM(wparam);

  const RECT content = ContentRectInClient();
  const float content_width =
      static_cast<float>(content.right - content.left);
  const float content_height =
      static_cast<float>(content.bottom - content.top);

  float normalized_x = Clamp01(static_cast<float>(point.x) / static_cast<float>(width));
  float normalized_y = Clamp01(static_cast<float>(point.y) / static_cast<float>(height));
  if (content_width > 0.0f && content_height > 0.0f && has_content_rect_) {
    const float within_content_x =
        Clamp01((static_cast<float>(point.x) - content.left) / content_width);
    const float within_content_y =
        Clamp01((static_cast<float>(point.y) - content.top) / content_height);
    normalized_x = content_rect_[0] + within_content_x * content_rect_[2];
    normalized_y = content_rect_[1] + within_content_y * content_rect_[3];
  }

  InputEvent event;
  event.type = 4;
  event.normalized_x = normalized_x;
  event.normalized_y = normalized_y;
  event.wheel_delta = windows_delta;
  input_handler_(event);
}

void NativeVideoView::EmitKeyEvent(int type, WPARAM wparam) {
  if (input_handler_ == nullptr) {
    return;
  }
  const int key_code = AndroidKeyCodeForVirtualKey(wparam);
  if (key_code == 0) {
    return;
  }
  InputEvent event;
  event.type = type;
  event.key_code = key_code;
  input_handler_(event);
}

int NativeVideoView::AndroidKeyCodeForVirtualKey(WPARAM virtual_key) {
  switch (virtual_key) {
    case VK_LEFT:
      return 21;  // KEYCODE_DPAD_LEFT
    case VK_UP:
      return 19;  // KEYCODE_DPAD_UP
    case VK_RIGHT:
      return 22;  // KEYCODE_DPAD_RIGHT
    case VK_DOWN:
      return 20;  // KEYCODE_DPAD_DOWN
    case VK_RETURN:
      return 66;  // KEYCODE_ENTER
    case VK_ESCAPE:
      return 4;  // KEYCODE_BACK
    case VK_BACK:
      return 67;  // KEYCODE_DEL
    case VK_TAB:
      return 61;  // KEYCODE_TAB
    case VK_SPACE:
      return 62;  // KEYCODE_SPACE
    case VK_HOME:
      return 3;  // KEYCODE_HOME
    case 'A':
      return 29;
    case 'B':
      return 30;
    case 'C':
      return 31;
    case 'D':
      return 32;
    case 'E':
      return 33;
    case 'F':
      return 34;
    case 'G':
      return 35;
    case 'H':
      return 36;
    case 'I':
      return 37;
    case 'J':
      return 38;
    case 'K':
      return 39;
    case 'L':
      return 40;
    case 'M':
      return 41;
    case 'N':
      return 42;
    case 'O':
      return 43;
    case 'P':
      return 44;
    case 'Q':
      return 45;
    case 'R':
      return 46;
    case 'S':
      return 47;
    case 'T':
      return 48;
    case 'U':
      return 49;
    case 'V':
      return 50;
    case 'W':
      return 51;
    case 'X':
      return 52;
    case 'Y':
      return 53;
    case 'Z':
      return 54;
    default:
      return 0;
  }
}

}  // namespace screen_cast_windows
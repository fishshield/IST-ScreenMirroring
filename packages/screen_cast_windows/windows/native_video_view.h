#ifndef SCREEN_CAST_WINDOWS_NATIVE_VIDEO_VIEW_H_
#define SCREEN_CAST_WINDOWS_NATIVE_VIDEO_VIEW_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstdint>
#include <functional>
#include <string>

#include "d3d11_renderer.h"

namespace screen_cast_windows {

// Input events captured on the video window, in the control-channel numbering
// (see lib/src/control/control_message.dart and ControlProtocol.java).
struct InputEvent {
  // 1 touch down, 2 touch move, 3 touch up, 4 wheel, 5 key down, 6 key up.
  int type = 0;
  // Normalized 0.0-1.0 client coordinates (touch and wheel).
  float normalized_x = 0.0f;
  float normalized_y = 0.0f;
  // Android KeyEvent keycode (key messages only).
  int key_code = 0;
  // Raw WM_MOUSEWHEEL delta in multiples of WHEEL_DELTA (120); positive = wheel
  // rotated away from the user. Sent unchanged end to end: the verified Android
  // side uses the same sign for AXIS_VSCROLL.
  int wheel_delta = 0;
};

using InputEventHandler = std::function<void(const InputEvent&)>;

// A standalone top-level window that presents the remote screen with D3D11.
//
// It used to be an owned popup glued to the Flutter preview rectangle. It is
// now an independent window (WS_POPUP | WS_THICKFRAME) so the user can move,
// resize, minimize and fullscreen it while the Flutter window keeps only the
// connection controls. The window draws no chrome: WM_NCCALCSIZE gives the
// whole window to the swap chain, and WM_NCHITTEST re-creates a 40 px drag
// strip plus resize borders.
//
// Closing the window (Alt+F4 / WM_CLOSE) hides it instead of destroying it, so
// the capture session keeps running; the tray menu can bring it back.
class NativeVideoView {
 public:
  NativeVideoView();
  ~NativeVideoView();

  NativeVideoView(const NativeVideoView&) = delete;
  NativeVideoView& operator=(const NativeVideoView&) = delete;

  // Creates the independent window. `flutter_view` is only used to pick the
  // monitor to center on; the video window is not owned by it.
  bool Create(HWND owner, HWND flutter_view);
  void Dispose();

  void Show();
  void Hide();
  bool visible() const;
  bool fullscreen() const { return fullscreen_; }
  void ToggleFullscreen();

  // Normalized sub-rect of the decoded frame that holds the mirrored screen.
  // Applying it crops the encoder's letterbox bars and sizes the window to the
  // content aspect (until the user moves/resizes the window).
  void SetContentRect(float x, float y, float width, float height);

  bool ConfigureVideoFrame(UINT width, UINT height, Nv12UploadMapping* mappings,
                           std::string* error);
  bool PresentVideoFrame(int index, Nv12UploadMapping* mapping,
                         std::string* error);

  // --- D3D11VA hardware-frame path (used through the C bridge) --------------
  bool AcquireDeviceHandles(void** device, void** context) const {
    return renderer_.AcquireDeviceHandles(device, context);
  }

  // Copies a hardware-decoded NV12 slice into the video texture. Returns
  // D3D11Renderer::HardwareCopyResult and invalidates the window on success.
  int CopyHardwareFrame(void* texture, intptr_t slice, UINT width, UINT height,
                        std::string* error);

  HWND hwnd() const { return hwnd_; }
  bool created() const { return hwnd_ != nullptr; }
  bool d3d_ready() const { return renderer_.ready(); }
  bool has_video_frame() const { return renderer_.has_video_frame(); }
  int present_fps() const { return renderer_.present_fps(); }
  UINT video_frame_width() const { return renderer_.frame_width(); }
  UINT video_frame_height() const { return renderer_.frame_height(); }
  int displayed_texture_index() const {
    return renderer_.displayed_texture_index();
  }
  const std::string& last_error() const { return renderer_.last_error(); }

  void SetInputEnabled(bool enabled);
  bool input_enabled() const { return input_enabled_; }
  void SetInputEventHandler(InputEventHandler handler);

  // Called once when the user finishes an interactive resize/move of the
  // window. The renderer reports it to Dart so the decoder can re-measure the
  // letterbox content rect (content probes are trigger driven).
  void SetResizeHandler(std::function<void()> handler);

  // Reports user-triggered show/hide (the close button hides instead of
  // destroying, so the session can be reopened).
  void SetVisibilityHandler(std::function<void(bool)> handler);

 private:
  static bool RegisterWindowClass();
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  LRESULT HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  LRESULT HitTest(LPARAM lparam) const;
  int ScaleForDpi(int value) const;
  int CaptionHeight() const;
  RECT CaptionRect() const;
  RECT CaptionButtonRect(int index) const;
  void PaintCaption(HDC dc);
  void RedrawCaption();
  void ApplyContentAspect();
  void ApplyInitialPlacement();
  void UpdateInitialAspect(UINT video_width, UINT video_height);
  void EnterFullscreen();
  void ExitFullscreen();

  // Smooth window transitions. The video window has no system frame, so
  // minimize/show/hide are animated by hand: a DWM-style fade for show/hide and
  // a short rect tween for the fullscreen toggle.
  void AnimateRectTo(const RECT& target, int duration_ms);
  void StopRectAnimation();
  LRESULT OnAnimationTimer();
  RECT ContentRectInClient() const;
  void EmitPointerEvent(int type, LPARAM lparam);
  void EmitWheelEvent(WPARAM wparam, LPARAM lparam);
  void EmitKeyEvent(int type, WPARAM wparam);
  static int AndroidKeyCodeForVirtualKey(WPARAM virtual_key);

  HWND hwnd_ = nullptr;
  HWND owner_ = nullptr;
  HWND flutter_view_ = nullptr;
  HBRUSH fallback_brush_ = nullptr;
  D3D11Renderer renderer_;

  bool input_enabled_ = false;
  bool fullscreen_ = false;
  bool shown_by_user_ = false;
  bool user_resized_ = false;
  bool has_content_rect_ = false;
  float content_rect_[4] = {0.0f, 0.0f, 1.0f, 1.0f};
  RECT restore_rect_ = {};
  LONG_PTR restore_style_ = 0;
  int initial_width_ = 640;
  int initial_height_ = 360;
  bool applied_initial_aspect_ = false;
  HFONT caption_font_ = nullptr;

  // Rect tween state for the fullscreen transition.
  bool rect_animating_ = false;
  RECT anim_from_ = {};
  RECT anim_to_ = {};
  DWORD anim_started_at_ = 0;
  int anim_duration_ms_ = 0;

  InputEventHandler input_handler_;
  std::function<void()> resize_handler_;
  std::function<void(bool)> visibility_handler_;
};

}  // namespace screen_cast_windows

#endif  // SCREEN_CAST_WINDOWS_NATIVE_VIDEO_VIEW_H_
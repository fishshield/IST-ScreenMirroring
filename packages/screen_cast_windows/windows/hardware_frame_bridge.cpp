#include "hardware_frame_bridge.h"

#include <windows.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "d3d11_renderer.h"
#include "native_video_view.h"

namespace screen_cast_windows {
namespace {

NativeVideoView* g_view = nullptr;

void WriteError(char* buffer, int length, const std::string& message) {
  if (buffer == nullptr || length <= 0) {
    return;
  }
  std::snprintf(buffer, static_cast<size_t>(length), "%s", message.c_str());
}

}  // namespace

void SetBridgeVideoView(NativeVideoView* view) { g_view = view; }

}  // namespace screen_cast_windows

extern "C" __declspec(dllexport) int screencast_hw_acquire_device(
    void** device, void** immediate_context) {
  if (device == nullptr || immediate_context == nullptr) {
    return -1;
  }
  *device = nullptr;
  *immediate_context = nullptr;
  screen_cast_windows::NativeVideoView* view = screen_cast_windows::g_view;
  if (view == nullptr || !view->created()) {
    return -1;
  }
  return view->AcquireDeviceHandles(device, immediate_context) ? 0 : -1;
}

extern "C" __declspec(dllexport) void screencast_hw_release_device(
    void* device, void* immediate_context) {
  if (device != nullptr) {
    static_cast<IUnknown*>(device)->Release();
  }
  if (immediate_context != nullptr) {
    static_cast<IUnknown*>(immediate_context)->Release();
  }
}

extern "C" __declspec(dllexport) int screencast_hw_copy_texture(
    void* texture, int64_t slice, int width, int height, char* error,
    int error_length) {
  if (texture == nullptr) {
    screen_cast_windows::WriteError(error, error_length,
                                    "decoded texture is null");
    return 2;
  }
  if (width <= 0 || height <= 0) {
    screen_cast_windows::WriteError(error, error_length,
                                    "invalid hardware frame dimensions");
    return 2;
  }
  screen_cast_windows::NativeVideoView* view = screen_cast_windows::g_view;
  if (view == nullptr || !view->created()) {
    screen_cast_windows::WriteError(error, error_length,
                                    "native overlay is not created");
    return -1;
  }

  std::string message;
  const int result = view->CopyHardwareFrame(
      texture, static_cast<intptr_t>(slice), static_cast<UINT>(width),
      static_cast<UINT>(height), &message);
  if (result != 0) {
    screen_cast_windows::WriteError(error, error_length,
                                    message.empty() ? "hardware copy failed"
                                                    : message);
  }
  return result;
}

#ifndef SCREEN_CAST_WINDOWS_HARDWARE_FRAME_BRIDGE_H_
#define SCREEN_CAST_WINDOWS_HARDWARE_FRAME_BRIDGE_H_

#include <cstdint>

// Synchronous C entry points for the D3D11VA decode path.
//
// The Dart side loads this plugin DLL and calls these functions directly with
// dart:ffi instead of going through the MethodChannel: the decoded texture has
// to be copied while FFmpeg's AVFrame is still alive inside the same decode
// call, so an asynchronous channel round trip is not an option.
//
// Error strings are copied into the caller's buffer; return codes are
// D3D11Renderer::HardwareCopyResult values (0 = ok, 1 = foreign device,
// 2 = failed) or -1 when the bridge has no overlay yet.

namespace screen_cast_windows {

class NativeVideoView;

// The plugin owns exactly one overlay; it registers it here so the exported
// functions can reach the renderer.
void SetBridgeVideoView(NativeVideoView* view);

}  // namespace screen_cast_windows

extern "C" {

// Returns the renderer's ID3D11Device/ID3D11DeviceContext with one reference
// each, for FFmpeg's AVD3D11VADeviceContext. Returns 0 on success, -1 when no
// overlay/device exists.
__declspec(dllexport) int screencast_hw_acquire_device(void** device,
                                                       void** immediate_context);

// Releases the two references if FFmpeg never took them over (hardware setup
// failed after acquisition).
__declspec(dllexport) void screencast_hw_release_device(void* device,
                                                        void* immediate_context);

// Copies one NV12 slice of a hardware-decoded texture into the overlay's video
// texture and schedules a redraw. `error` may be null; otherwise it must point
// at `error_length` writable bytes.
__declspec(dllexport) int screencast_hw_copy_texture(void* texture,
                                                     int64_t slice,
                                                     int width,
                                                     int height,
                                                     char* error,
                                                     int error_length);

}  // extern "C"

#endif  // SCREEN_CAST_WINDOWS_HARDWARE_FRAME_BRIDGE_H_

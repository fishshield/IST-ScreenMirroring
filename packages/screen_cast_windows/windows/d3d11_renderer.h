#ifndef SCREEN_CAST_WINDOWS_D3D11_RENDERER_H_
#define SCREEN_CAST_WINDOWS_D3D11_RENDERER_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>

#include <cstdint>
#include <chrono>
#include <string>

namespace screen_cast_windows {

// Number of NV12 staging textures used for double-buffered CPU uploads.
constexpr int kNv12UploadTextureCount = 2;

// One CPU-writable NV12 staging texture and its current mapping layout.
struct Nv12UploadMapping {
  uintptr_t data = 0;
  UINT row_pitch = 0;
};

// D3D11 renderer for the owned Win32 overlay.
//
// Decoded frames arrive as YUV420p in Dart. The Dart side writes NV12 directly
// into one of two persistently-mapped staging textures; PresentVideoFrame()
// unmaps that texture, copies it to a shader-readable DXGI_FORMAT_NV12 texture,
// remaps the same staging texture, and draws the last frame. Two textures are
// rotated so the texture being presented and the texture being written are
// never the same resource. When no frame has arrived yet the renderer falls
// back to the original teal clear color; after the first frame it keeps drawing
// the last texture instead of clearing.
class D3D11Renderer {
 public:
  D3D11Renderer();
  ~D3D11Renderer();

  D3D11Renderer(const D3D11Renderer&) = delete;
  D3D11Renderer& operator=(const D3D11Renderer&) = delete;

  bool Initialize(HWND hwnd);
  bool Resize(UINT width, UINT height);
  void Render();
  void Shutdown();

  // Creates/recreates the NV12 textures for the given decoded dimensions,
  // maps both upload textures for CPU writes, and fills
  // mappings[0..kNv12UploadTextureCount). The returned pointers remain valid
  // until the next PresentVideoFrame() of that index or a new
  // ConfigureVideoFrame() call. Both dimensions must be even and non-zero.
  bool ConfigureVideoFrame(UINT width, UINT height,
                           Nv12UploadMapping* mappings, std::string* error);

  // Commits the NV12 bytes already written through mappings[index].data,
  // copies that upload texture to the video texture, remaps the same staging
  // texture, and draws. Returns the new mapping for that index, which can
  // change on every map. The other upload texture is left untouched, so its
  // pointer stays valid.
  bool PresentVideoFrame(int index, Nv12UploadMapping* mapping,
                         std::string* error);

  bool ready() const { return render_target_view_ != nullptr; }
  bool has_video_frame() const { return has_frame_; }
  UINT frame_width() const { return frame_width_; }
  UINT frame_height() const { return frame_height_; }

  /// Swap-chain presents per second, sampled once per second in Render().
  /// This is what the user actually sees, independent of the decode rate.
  int present_fps() const { return present_fps_; }

  // Result of CopyHardwareFrame().
  enum HardwareCopyResult {
    kHardwareCopyOk = 0,
    // The texture belongs to another ID3D11Device (FFmpeg created its own).
    kHardwareCopyForeignDevice = 1,
    kHardwareCopyFailed = 2,
  };

  // Hands out one AddRef'd reference to the renderer's device and immediate
  // context, for FFmpeg's AVD3D11VADeviceContext. The caller owns both
  // references and must hand them to av_hwdevice_ctx_init (which releases
  // them) or give them back through the bridge.
  bool AcquireDeviceHandles(void** device, void** context) const;

  // Copies one NV12 array slice of a hardware-decoded texture into the video
  // texture with CopySubresourceRegion. No CPU mapping is involved: this is the
  // D3D11VA replacement for the Nv12FrameWriter upload.
  HardwareCopyResult CopyHardwareFrame(ID3D11Texture2D* texture, UINT slice,
                                       UINT width, UINT height,
                                       std::string* error);

  // Normalized sub-rect of the decoded frame that actually holds the mirrored
  // phone screen. The encoder letterboxes the phone inside the 16:9 frame, so
  // sampling only this rect removes the baked-in black bars. Defaults to the
  // whole frame.
  void SetContentRect(float x, float y, float width, float height);


  // Index of the upload texture most recently copied into the video texture,
  // or -1 before the first present. Exposed for diagnostics.
  int displayed_texture_index() const { return displayed_index_; }

  const std::string& last_error() const { return last_error_; }

 private:
  bool RecreateSwapChain();
  bool CreateDeviceAndSwapChain(D3D_DRIVER_TYPE driver_type,
                                const DXGI_SWAP_CHAIN_DESC& desc);
  bool CreateRenderTarget();
  bool CreateFramePipeline(std::string* error);
  bool CreateVideoTextures(UINT width, UINT height, std::string* error);
  bool EnsureVideoTexture(UINT width, UINT height, std::string* error);
  bool MapUploadTexture(int index, std::string* error);
  void ReleaseVideoResources();
  void SetError(std::string* error, const std::string& message);
  // Presents the swap chain and folds the call into the 1 s fps window.
  void PresentSwapChain();

  HWND hwnd_ = nullptr;
  UINT width_ = 0;
  UINT height_ = 0;

  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<IDXGISwapChain> swap_chain_;
  Microsoft::WRL::ComPtr<ID3D11RenderTargetView> render_target_view_;

  Microsoft::WRL::ComPtr<ID3D11VertexShader> vertex_shader_;
  Microsoft::WRL::ComPtr<ID3D11PixelShader> pixel_shader_;
  Microsoft::WRL::ComPtr<ID3D11SamplerState> sampler_;
  Microsoft::WRL::ComPtr<ID3D11RasterizerState> rasterizer_;

  Microsoft::WRL::ComPtr<ID3D11Texture2D> video_texture_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D>
      upload_textures_[kNv12UploadTextureCount];
  Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> y_texture_view_;
  Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> uv_texture_view_;

  // x, y, width, height in normalized frame coordinates.
  float content_rect_[4] = {0.0f, 0.0f, 1.0f, 1.0f};
  bool has_content_rect_ = false;

  D3D11_MAPPED_SUBRESOURCE mapped_[kNv12UploadTextureCount] = {};
  bool upload_mapped_[kNv12UploadTextureCount] = {};
  int displayed_index_ = -1;
  bool has_frame_ = false;
  UINT frame_width_ = 0;
  UINT frame_height_ = 0;

  DXGI_SWAP_CHAIN_DESC swap_desc_ = {};
  std::string last_error_;

  std::chrono::steady_clock::time_point present_window_start_ =
      std::chrono::steady_clock::now();
  int present_window_count_ = 0;
  int present_fps_ = 0;
};

}  // namespace screen_cast_windows

#endif  // SCREEN_CAST_WINDOWS_D3D11_RENDERER_H_
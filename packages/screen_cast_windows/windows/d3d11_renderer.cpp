#include "d3d11_renderer.h"

#include <combaseapi.h>
#include <d3dcompiler.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <iterator>
#include <utility>

namespace screen_cast_windows {

namespace {

constexpr char kVertexShaderSource[] = R"(
struct VSOut {
  float4 position : SV_POSITION;
  float2 uv : TEXCOORD0;
};

VSOut VSMain(uint vertex_id : SV_VertexID) {
  // Full-viewport quad generated without a vertex buffer. The position uses
  // NDC and the UV origin is the top-left of the decoded frame.
  static const float2 positions[4] = {
      float2(-1.0, 1.0),
      float2(1.0, 1.0),
      float2(-1.0, -1.0),
      float2(1.0, -1.0),
  };
  static const float2 uvs[4] = {
      float2(0.0, 0.0),
      float2(1.0, 0.0),
      float2(0.0, 1.0),
      float2(1.0, 1.0),
  };

  VSOut output;
  output.position = float4(positions[vertex_id], 0.0, 1.0);
  output.uv = uvs[vertex_id];
  return output;
}
)";

constexpr char kPixelShaderSource[] = R"(
Texture2D<float> y_texture : register(t0);
Texture2D<float2> uv_texture : register(t1);
SamplerState linear_sampler : register(s0);

struct VSOut {
  float4 position : SV_POSITION;
  float2 uv : TEXCOORD0;
};

float4 PSMain(VSOut input) : SV_Target {
  // Fixed BT.601 limited-range matrix. No color metadata or tone mapping is
  // applied in this first renderer.
  float y = y_texture.Sample(linear_sampler, input.uv).r;
  float2 uv = uv_texture.Sample(linear_sampler, input.uv).rg;

  float luma = saturate((y - (16.0 / 255.0)) * (255.0 / 219.0));
  float u = (uv.x - (128.0 / 255.0)) * (255.0 / 224.0);
  float v = (uv.y - (128.0 / 255.0)) * (255.0 / 224.0);

  float3 rgb;
  rgb.r = luma + (1.402 * v);
  rgb.g = luma - (0.344136 * u) - (0.714136 * v);
  rgb.b = luma + (1.772 * u);
  return float4(saturate(rgb), 1.0);
}
)";

std::string HResultText(const char* operation, HRESULT result) {
  char buffer[160] = {};
  std::snprintf(buffer, sizeof(buffer), "%s failed (HRESULT 0x%08lX).",
                operation, static_cast<unsigned long>(result));
  return std::string(buffer);
}

bool IsEvenAndPositive(UINT value) {
  return value > 0 && (value % 2u) == 0;
}

}  // namespace

D3D11Renderer::D3D11Renderer() = default;

D3D11Renderer::~D3D11Renderer() {
  Shutdown();
}

bool D3D11Renderer::Initialize(HWND hwnd) {
  if (hwnd == nullptr) {
    return false;
  }
  Shutdown();
  hwnd_ = hwnd;

  RECT client = {};
  GetClientRect(hwnd_, &client);
  width_ = static_cast<UINT>(std::max<LONG>(client.right - client.left, 1L));
  height_ = static_cast<UINT>(std::max<LONG>(client.bottom - client.top, 1L));

  DXGI_SWAP_CHAIN_DESC desc = {};
  desc.BufferCount = 1;
  desc.BufferDesc.Width = width_;
  desc.BufferDesc.Height = height_;
  desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.BufferDesc.RefreshRate.Numerator = 60;
  desc.BufferDesc.RefreshRate.Denominator = 1;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.OutputWindow = hwnd_;
  desc.SampleDesc.Count = 1;
  desc.Windowed = TRUE;
  desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

  if (!CreateDeviceAndSwapChain(D3D_DRIVER_TYPE_HARDWARE, desc)) {
    // Remote desktop / VM sessions may not expose a hardware D3D device.
    if (!CreateDeviceAndSwapChain(D3D_DRIVER_TYPE_WARP, desc)) {
      last_error_ = "D3D11 device/swap-chain creation failed.";
      return false;
    }
  }

  if (!CreateRenderTarget()) {
    last_error_ = "D3D11 render-target creation failed.";
    return false;
  }

  if (!CreateFramePipeline(&last_error_)) {
    // D3D11 can still present the placeholder, but frame upload will fail with
    // a useful diagnostic through configureFrame.
    last_error_ = "D3D11 frame pipeline initialization failed: " + last_error_;
  }
  return true;
}

bool D3D11Renderer::CreateDeviceAndSwapChain(
    D3D_DRIVER_TYPE driver_type,
    const DXGI_SWAP_CHAIN_DESC& desc) {
  DXGI_SWAP_CHAIN_DESC mutable_desc = desc;
  const UINT flags = 0;
  const D3D_FEATURE_LEVEL feature_levels[] = {
      D3D_FEATURE_LEVEL_11_1,
      D3D_FEATURE_LEVEL_11_0,
  };
  HRESULT result = D3D11CreateDeviceAndSwapChain(
      nullptr, driver_type, nullptr, flags, feature_levels,
      static_cast<UINT>(std::size(feature_levels)), D3D11_SDK_VERSION,
      &mutable_desc, swap_chain_.GetAddressOf(), device_.GetAddressOf(),
      nullptr, context_.GetAddressOf());
  if (FAILED(result)) {
    // Some Windows configurations reject an explicit 11_1 request. Let the
    // runtime choose its highest supported level before falling back to WARP.
    result = D3D11CreateDeviceAndSwapChain(
        nullptr, driver_type, nullptr, flags, nullptr, 0, D3D11_SDK_VERSION,
        &mutable_desc, swap_chain_.GetAddressOf(), device_.GetAddressOf(),
        nullptr, context_.GetAddressOf());
  }
  if (SUCCEEDED(result)) {
    swap_desc_ = mutable_desc;
  }
  return SUCCEEDED(result);
}

bool D3D11Renderer::RecreateSwapChain() {
  if (!device_) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  if (FAILED(device_.As(&dxgi_device))) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
  if (FAILED(dxgi_device->GetAdapter(adapter.GetAddressOf()))) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIFactory> factory;
  if (FAILED(adapter->GetParent(IID_PPV_ARGS(factory.GetAddressOf())))) {
    return false;
  }

  render_target_view_.Reset();
  swap_chain_.Reset();
  DXGI_SWAP_CHAIN_DESC desc = swap_desc_;
  if (width_ > 0 && height_ > 0) {
    desc.BufferDesc.Width = width_;
    desc.BufferDesc.Height = height_;
  }
  Microsoft::WRL::ComPtr<IDXGISwapChain> chain;
  HRESULT result =
      factory->CreateSwapChain(device_.Get(), &desc, chain.GetAddressOf());
  if (FAILED(result)) {
    last_error_ = HResultText("CreateSwapChain", result);
    return false;
  }
  swap_chain_ = chain;
  return CreateRenderTarget();
}

bool D3D11Renderer::CreateRenderTarget() {
  if (!swap_chain_ || !device_) {
    return false;
  }

  Microsoft::WRL::ComPtr<ID3D11Texture2D> back_buffer;
  HRESULT result = swap_chain_->GetBuffer(
      0, IID_PPV_ARGS(back_buffer.GetAddressOf()));
  if (FAILED(result)) {
    last_error_ = HResultText("IDXGISwapChain::GetBuffer", result);
    return false;
  }

  render_target_view_.Reset();
  result = device_->CreateRenderTargetView(
      back_buffer.Get(), nullptr, render_target_view_.GetAddressOf());
  if (FAILED(result)) {
    last_error_ = HResultText("CreateRenderTargetView", result);
    return false;
  }
  return true;
}

bool D3D11Renderer::CreateFramePipeline(std::string* error) {
  if (!device_) {
    SetError(error, "D3D11 device is unavailable.");
    return false;
  }

  if (sampler_ == nullptr) {
    D3D11_SAMPLER_DESC sampler_desc = {};
    sampler_desc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sampler_desc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampler_desc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampler_desc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampler_desc.MaxAnisotropy = 1;
    sampler_desc.ComparisonFunc = D3D11_COMPARISON_NEVER;
    sampler_desc.MinLOD = 0;
    sampler_desc.MaxLOD = D3D11_FLOAT32_MAX;
    HRESULT result = device_->CreateSamplerState(
        &sampler_desc, sampler_.GetAddressOf());
    if (FAILED(result)) {
      SetError(error, HResultText("CreateSamplerState", result));
      return false;
    }
  }

  if (rasterizer_ == nullptr) {
    D3D11_RASTERIZER_DESC rasterizer_desc = {};
    rasterizer_desc.FillMode = D3D11_FILL_SOLID;
    rasterizer_desc.CullMode = D3D11_CULL_NONE;
    rasterizer_desc.DepthClipEnable = TRUE;
    HRESULT result = device_->CreateRasterizerState(
        &rasterizer_desc, rasterizer_.GetAddressOf());
    if (FAILED(result)) {
      SetError(error, HResultText("CreateRasterizerState", result));
      return false;
    }
  }

  if (vertex_shader_ == nullptr) {
    Microsoft::WRL::ComPtr<ID3DBlob> shader_blob;
    Microsoft::WRL::ComPtr<ID3DBlob> errors;
    HRESULT result = D3DCompile(
        kVertexShaderSource, sizeof(kVertexShaderSource) - 1, "video_vs",
        nullptr, nullptr, "VSMain", "vs_5_0", D3DCOMPILE_ENABLE_STRICTNESS,
        0, shader_blob.GetAddressOf(), errors.GetAddressOf());
    if (FAILED(result)) {
      const char* message = errors != nullptr
                                ? static_cast<const char*>(errors->GetBufferPointer())
                                : "no compiler diagnostic";
      SetError(error, std::string("D3DCompile vertex shader failed: ") + message);
      return false;
    }
    result = device_->CreateVertexShader(
        shader_blob->GetBufferPointer(), shader_blob->GetBufferSize(), nullptr,
        vertex_shader_.GetAddressOf());
    if (FAILED(result)) {
      SetError(error, HResultText("CreateVertexShader", result));
      return false;
    }
  }

  if (pixel_shader_ == nullptr) {
    Microsoft::WRL::ComPtr<ID3DBlob> shader_blob;
    Microsoft::WRL::ComPtr<ID3DBlob> errors;
    HRESULT result = D3DCompile(
        kPixelShaderSource, sizeof(kPixelShaderSource) - 1, "video_ps",
        nullptr, nullptr, "PSMain", "ps_5_0", D3DCOMPILE_ENABLE_STRICTNESS,
        0, shader_blob.GetAddressOf(), errors.GetAddressOf());
    if (FAILED(result)) {
      const char* message = errors != nullptr
                                ? static_cast<const char*>(errors->GetBufferPointer())
                                : "no compiler diagnostic";
      SetError(error, std::string("D3DCompile pixel shader failed: ") + message);
      return false;
    }
    result = device_->CreatePixelShader(
        shader_blob->GetBufferPointer(), shader_blob->GetBufferSize(), nullptr,
        pixel_shader_.GetAddressOf());
    if (FAILED(result)) {
      SetError(error, HResultText("CreatePixelShader", result));
      return false;
    }
  }

  return true;
}

bool D3D11Renderer::CreateVideoTextures(UINT width, UINT height,
                                        std::string* error) {
  if (!device_ || !context_) {
    SetError(error, "D3D11 device is unavailable.");
    return false;
  }
  if (!IsEvenAndPositive(width) || !IsEvenAndPositive(height)) {
    SetError(error, "NV12 frame dimensions must be positive and even.");
    return false;
  }

  UINT format_support = 0;
  HRESULT result = device_->CheckFormatSupport(DXGI_FORMAT_NV12,
                                               &format_support);
  if (FAILED(result) ||
      (format_support & D3D11_FORMAT_SUPPORT_TEXTURE2D) == 0 ||
      (format_support & D3D11_FORMAT_SUPPORT_SHADER_SAMPLE) == 0) {
    SetError(error, "DXGI_FORMAT_NV12 shader sampling is not supported.");
    return false;
  }

  D3D11_TEXTURE2D_DESC video_desc = {};
  video_desc.Width = width;
  video_desc.Height = height;
  video_desc.MipLevels = 1;
  video_desc.ArraySize = 1;
  video_desc.Format = DXGI_FORMAT_NV12;
  video_desc.SampleDesc.Count = 1;
  video_desc.Usage = D3D11_USAGE_DEFAULT;
  video_desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;

  result = device_->CreateTexture2D(
      &video_desc, nullptr, video_texture_.GetAddressOf());
  if (FAILED(result)) {
    SetError(error, HResultText("CreateTexture2D(NV12 video)", result));
    return false;
  }

  // A staging texture is the only CPU-writable resource in this path. Dart
  // writes NV12 directly into its mapped memory, so no pixel array ever crosses
  // a MethodChannel and there is no extra CPU-side copy before the GPU copy.
  // Two textures are rotated so a frame can be written while the previous one
  // is still being presented.
  D3D11_TEXTURE2D_DESC upload_desc = video_desc;
  upload_desc.Usage = D3D11_USAGE_STAGING;
  upload_desc.BindFlags = 0;
  upload_desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  for (int index = 0; index < kNv12UploadTextureCount; ++index) {
    result = device_->CreateTexture2D(
        &upload_desc, nullptr, upload_textures_[index].GetAddressOf());
    if (FAILED(result)) {
      SetError(error, HResultText("CreateTexture2D(NV12 staging)", result));
      return false;
    }
  }

  // NV12 is one resource with a Y plane and an interleaved UV plane. D3D11
  // exposes the planes through two single-layer Texture2D views; using a
  // Texture2DArray for plane selection is not portable across vendors/WARP.
  D3D11_SHADER_RESOURCE_VIEW_DESC y_view_desc = {};
  y_view_desc.Format = DXGI_FORMAT_R8_UNORM;
  y_view_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
  y_view_desc.Texture2D.MostDetailedMip = 0;
  y_view_desc.Texture2D.MipLevels = 1;
  result = device_->CreateShaderResourceView(
      video_texture_.Get(), &y_view_desc, y_texture_view_.GetAddressOf());
  if (FAILED(result)) {
    SetError(error, HResultText("CreateShaderResourceView(NV12 Y)", result));
    return false;
  }

  D3D11_SHADER_RESOURCE_VIEW_DESC uv_view_desc = y_view_desc;
  uv_view_desc.Format = DXGI_FORMAT_R8G8_UNORM;
  result = device_->CreateShaderResourceView(
      video_texture_.Get(), &uv_view_desc, uv_texture_view_.GetAddressOf());
  if (FAILED(result)) {
    SetError(error, HResultText("CreateShaderResourceView(NV12 UV)", result));
    return false;
  }

  frame_width_ = width;
  frame_height_ = height;
  has_frame_ = false;
  displayed_index_ = -1;
  for (int index = 0; index < kNv12UploadTextureCount; ++index) {
    if (!MapUploadTexture(index, error)) {
      return false;
    }
  }
  return true;
}

bool D3D11Renderer::MapUploadTexture(int index, std::string* error) {
  if (index < 0 || index >= kNv12UploadTextureCount) {
    SetError(error, "NV12 upload texture index is out of range.");
    return false;
  }
  if (!context_ || !upload_textures_[index]) {
    SetError(error, "NV12 upload texture is unavailable.");
    return false;
  }
  if (upload_mapped_[index]) {
    return true;
  }

  mapped_[index] = {};
  HRESULT result = context_->Map(
      upload_textures_[index].Get(), 0, D3D11_MAP_WRITE, 0, &mapped_[index]);
  if (FAILED(result) || mapped_[index].pData == nullptr) {
    SetError(error, HResultText("Map(NV12 staging)", result));
    return false;
  }
  upload_mapped_[index] = true;
  return true;
}

bool D3D11Renderer::EnsureVideoTexture(UINT width, UINT height,
                                       std::string* error) {
  if (!device_ || !context_) {
    SetError(error, "D3D11 device is unavailable.");
    return false;
  }
  if (!IsEvenAndPositive(width) || !IsEvenAndPositive(height)) {
    SetError(error, "NV12 frame dimensions must be positive and even.");
    return false;
  }
  if (video_texture_ && y_texture_view_ && uv_texture_view_ &&
      frame_width_ == width && frame_height_ == height) {
    return true;
  }
  // The hardware path only needs the shader-readable video texture. Creating
  // the pair of staging textures as well keeps ConfigureVideoFrame() from
  // having to rebuild anything if the decoder falls back to software.
  ReleaseVideoResources();
  return CreateVideoTextures(width, height, error);
}

bool D3D11Renderer::AcquireDeviceHandles(void** device, void** context) const {
  if (device == nullptr || context == nullptr) {
    return false;
  }
  *device = nullptr;
  *context = nullptr;
  if (!device_ || !context_) {
    return false;
  }
  // FFmpeg's AVHWDeviceContext takes ownership of both references and releases
  // them when the hw device context is freed.
  device_->AddRef();
  context_->AddRef();
  *device = device_.Get();
  *context = context_.Get();
  return true;
}

D3D11Renderer::HardwareCopyResult D3D11Renderer::CopyHardwareFrame(
    ID3D11Texture2D* texture, UINT slice, UINT width, UINT height,
    std::string* error) {
  if (!device_ || !context_ || texture == nullptr) {
    SetError(error, "D3D11 renderer or hardware frame is unavailable.");
    return kHardwareCopyFailed;
  }

  Microsoft::WRL::ComPtr<ID3D11Device> source_device;
  texture->GetDevice(source_device.GetAddressOf());
  if (!source_device || source_device.Get() != device_.Get()) {
    // CopySubresourceRegion cannot cross devices; the caller has to download
    // the frame instead.
    SetError(error, "Hardware frame belongs to another D3D11 device.");
    return kHardwareCopyForeignDevice;
  }

  // Crop the encoder's letterbox bars: the shader samples only the content
  // sub-rect and the viewport keeps the phone aspect ratio.
  if (!EnsureVideoTexture(width, height, error)) {
    return kHardwareCopyFailed;
  }

  // NV12 hardware frames are a texture array; `slice` selects the element.
  // The same device means a straight GPU->GPU copy, no CPU mapping.
  context_->CopySubresourceRegion(video_texture_.Get(), 0, 0, 0, 0, texture,
                                  slice, nullptr);
  has_frame_ = true;
  return kHardwareCopyOk;
}

bool D3D11Renderer::ConfigureVideoFrame(UINT width, UINT height,
                                        Nv12UploadMapping* mappings,
                                        std::string* error) {
  if (mappings == nullptr) {
    SetError(error, "configureFrame requires output mapping parameters.");
    return false;
  }
  for (int index = 0; index < kNv12UploadTextureCount; ++index) {
    mappings[index] = {};
  }

  if (!ready() || !context_ || !device_) {
    SetError(error, "D3D11 renderer is not initialized.");
    return false;
  }
  if (!CreateFramePipeline(error)) {
    return false;
  }

  if (video_texture_ == nullptr || upload_textures_[0] == nullptr ||
      upload_textures_[1] == nullptr || frame_width_ != width ||
      frame_height_ != height) {
    ReleaseVideoResources();
    if (!CreateVideoTextures(width, height, error)) {
      ReleaseVideoResources();
      return false;
    }
  } else {
    // Same size: reuse the textures, remapping only the ones that were left
    // unmapped by a previous present.
    for (int index = 0; index < kNv12UploadTextureCount; ++index) {
      if (!upload_mapped_[index] && !MapUploadTexture(index, error)) {
        return false;
      }
    }
  }

  bool valid = true;
  for (int index = 0; index < kNv12UploadTextureCount; ++index) {
    mappings[index].data = reinterpret_cast<uintptr_t>(
        static_cast<BYTE*>(mapped_[index].pData));
    mappings[index].row_pitch = mapped_[index].RowPitch;
    valid = valid && mappings[index].data != 0 && mappings[index].row_pitch >= width;
  }
  if (!valid) {
    SetError(error, "NV12 upload textures returned an invalid layout.");
    return false;
  }
  return true;
}

bool D3D11Renderer::PresentVideoFrame(int index, Nv12UploadMapping* mapping,
                                      std::string* error) {
  if (mapping == nullptr) {
    SetError(error, "presentFrame requires an output mapping parameter.");
    return false;
  }
  *mapping = {};

  if (index < 0 || index >= kNv12UploadTextureCount) {
    SetError(error, "NV12 upload texture index is out of range.");
    return false;
  }
  if (!context_ || !upload_textures_[index] || !video_texture_) {
    SetError(error, "No NV12 frame is configured.");
    return false;
  }
  if (!upload_mapped_[index]) {
    SetError(error, "NV12 upload texture is not mapped.");
    return false;
  }

  // Keep this order: Unmap -> CopyResource -> Map. The Map afterwards yields a
  // fresh CPU pointer because D3D11 does not guarantee a stable mapping across
  // unmap/map cycles.
  context_->Unmap(upload_textures_[index].Get(), 0);
  upload_mapped_[index] = false;
  mapped_[index] = {};
  context_->CopyResource(video_texture_.Get(), upload_textures_[index].Get());
  has_frame_ = true;
  displayed_index_ = index;

  if (!MapUploadTexture(index, error)) {
    return false;
  }
  mapping->data = reinterpret_cast<uintptr_t>(
      static_cast<BYTE*>(mapped_[index].pData));
  mapping->row_pitch = mapped_[index].RowPitch;
  if (mapping->data == 0 || mapping->row_pitch < frame_width_) {
    SetError(error, "NV12 upload texture remap returned an invalid layout.");
    return false;
  }

  Render();
  return true;
}

bool D3D11Renderer::Resize(UINT width, UINT height) {
  if (!swap_chain_ || width == 0 || height == 0) {
    return false;
  }
  if (width == width_ && height == height_ && render_target_view_) {
    return true;
  }

  if (context_) {
    context_->OMSetRenderTargets(0, nullptr, nullptr);
  }
  // ResizeBuffers can fail (for example while the window is dragged between
  // monitors or right after a style change). Keep the previous target so the
  // renderer stays ready, then rebuild the swap chain at the new size; without
  // this the client and the back buffer diverge and DWM stretches a stale
  // frame, which also breaks pointer mapping.
  Microsoft::WRL::ComPtr<ID3D11RenderTargetView> previous_target =
      render_target_view_;
  render_target_view_.Reset();

  HRESULT result = swap_chain_->ResizeBuffers(
      0, width, height, DXGI_FORMAT_UNKNOWN, 0);
  if (FAILED(result)) {
    last_error_ = HResultText("ResizeBuffers", result);
    render_target_view_ = previous_target;
    width_ = width;
    height_ = height;
    return RecreateSwapChain();
  }

  width_ = width;
  height_ = height;
  swap_desc_.BufferDesc.Width = width;
  swap_desc_.BufferDesc.Height = height;
  return CreateRenderTarget();
}

void D3D11Renderer::SetContentRect(float x, float y, float width,
                                   float height) {
  if (!(width > 0.0f) || !(height > 0.0f)) {
    return;
  }
  if (x < 0.0f) {
    x = 0.0f;
  }
  if (y < 0.0f) {
    y = 0.0f;
  }
  if (x + width > 1.0f) {
    width = 1.0f - x;
  }
  if (y + height > 1.0f) {
    height = 1.0f - y;
  }
  if (!(width > 0.0f) || !(height > 0.0f)) {
    return;
  }
  content_rect_[0] = x;
  content_rect_[1] = y;
  content_rect_[2] = width;
  content_rect_[3] = height;
  has_content_rect_ = true;
}

void D3D11Renderer::PresentSwapChain() {
  if (!swap_chain_) {
    return;
  }
  swap_chain_->Present(1, 0);
  ++present_window_count_;
  const auto now = std::chrono::steady_clock::now();
  if (now - present_window_start_ >= std::chrono::seconds(1)) {
    present_fps_ = present_window_count_;
    present_window_count_ = 0;
    present_window_start_ = now;
  }
}

void D3D11Renderer::Render() {
  if (!context_ || !swap_chain_ || !render_target_view_) {
    return;
  }

  const float clear_placeholder[4] = {0.047f, 0.282f, 0.251f, 1.0f};
  const float clear_video[4] = {0.0f, 0.0f, 0.0f, 1.0f};
  const bool draw_video = has_frame_ && vertex_shader_ && pixel_shader_ &&
                          y_texture_view_ && uv_texture_view_ && sampler_;

  ID3D11RenderTargetView* render_targets[] = {
      render_target_view_.Get(),
  };
  context_->OMSetRenderTargets(1, render_targets, nullptr);

  D3D11_VIEWPORT viewport = {};
  viewport.Width = static_cast<float>(width_);
  viewport.Height = static_cast<float>(height_);
  viewport.MinDepth = 0.0f;
  viewport.MaxDepth = 1.0f;

  if (!draw_video) {
    context_->RSSetViewports(1, &viewport);
    context_->ClearRenderTargetView(render_target_view_.Get(),
                                    clear_placeholder);
    PresentSwapChain();
    return;
  }

  // Keep the last committed video texture on screen. No frame arrival never
  // clears the target; WM_PAINT and resizes redraw the same texture.
  context_->ClearRenderTargetView(render_target_view_.Get(), clear_video);

  // Crop the encoder's letterbox bars with viewport arithmetic: map the whole
  // frame to a rect that is scaled up so its content sub-rect covers the
  // client exactly. Bars land outside the render target and get clipped, so no
  // shader constants or texture copies are involved.
  if (frame_width_ > 0 && frame_height_ > 0 && width_ > 0 && height_ > 0) {
    const float content_width =
        content_rect_[2] * static_cast<float>(frame_width_);
    const float content_height =
        content_rect_[3] * static_cast<float>(frame_height_);
    if (content_width > 0.0f && content_height > 0.0f) {
      const float content_aspect = content_width / content_height;
      const float client_width = static_cast<float>(width_);
      const float client_height = static_cast<float>(height_);
      float dest_width = client_width;
      float dest_height = client_height;
      if (client_width / client_height > content_aspect) {
        dest_width = client_height * content_aspect;
      } else {
        dest_height = client_width / content_aspect;
      }
      const float dest_x = (client_width - dest_width) * 0.5f;
      const float dest_y = (client_height - dest_height) * 0.5f;
      viewport.Width = dest_width / content_rect_[2];
      viewport.Height = dest_height / content_rect_[3];
      viewport.TopLeftX = dest_x - content_rect_[0] * viewport.Width;
      viewport.TopLeftY = dest_y - content_rect_[1] * viewport.Height;
    }
  }
  context_->RSSetViewports(1, &viewport);
  context_->IASetInputLayout(nullptr);
  context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
  context_->IASetVertexBuffers(0, 0, nullptr, nullptr, nullptr);
  context_->VSSetShader(vertex_shader_.Get(), nullptr, 0);
  context_->PSSetShader(pixel_shader_.Get(), nullptr, 0);

  ID3D11ShaderResourceView* views[] = {
      y_texture_view_.Get(),
      uv_texture_view_.Get(),
  };
  context_->PSSetShaderResources(0, 2, views);
  ID3D11SamplerState* samplers[] = {sampler_.Get()};
  context_->PSSetSamplers(0, 1, samplers);
  context_->RSSetState(rasterizer_.Get());
  context_->Draw(4, 0);

  // Unbind the video SRVs before the next CopyResource. Leaving a resource
  // bound as an SRV while writing it can generate a D3D11 warning or force an
  // unnecessary copy-on-write.
  ID3D11ShaderResourceView* null_views[2] = {nullptr, nullptr};
  context_->PSSetShaderResources(0, 2, null_views);

  PresentSwapChain();
}

void D3D11Renderer::Shutdown() {
  ReleaseVideoResources();
  y_texture_view_.Reset();
  uv_texture_view_.Reset();
  pixel_shader_.Reset();
  vertex_shader_.Reset();
  sampler_.Reset();
  rasterizer_.Reset();
  render_target_view_.Reset();
  swap_chain_.Reset();
  context_.Reset();
  device_.Reset();
  hwnd_ = nullptr;
  width_ = 0;
  height_ = 0;
  last_error_.clear();
}

void D3D11Renderer::ReleaseVideoResources() {
  if (context_) {
    for (int index = 0; index < kNv12UploadTextureCount; ++index) {
      if (upload_mapped_[index] && upload_textures_[index]) {
        context_->Unmap(upload_textures_[index].Get(), 0);
      }
    }
  }
  for (int index = 0; index < kNv12UploadTextureCount; ++index) {
    upload_mapped_[index] = false;
    mapped_[index] = {};
    upload_textures_[index].Reset();
  }
  displayed_index_ = -1;
  has_frame_ = false;
  frame_width_ = 0;
  frame_height_ = 0;
  y_texture_view_.Reset();
  uv_texture_view_.Reset();
  video_texture_.Reset();
}

void D3D11Renderer::SetError(std::string* error, const std::string& message) {
  last_error_ = message;
  if (error != nullptr) {
    *error = message;
  }
}

}  // namespace screen_cast_windows
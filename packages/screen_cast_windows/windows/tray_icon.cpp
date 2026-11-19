#include "tray_icon.h"

#include <cwchar>

namespace screen_cast_windows {

namespace {

constexpr UINT kTrayIconId = 1;
constexpr int kIconSize = 32;

}  // namespace

TrayIcon::TrayIcon() {
  connected_icon_ = CreateStatusIcon(RGB(53, 224, 161), RGB(20, 120, 90));
  idle_icon_ = CreateStatusIcon(RGB(120, 132, 145), RGB(70, 80, 92));
}

TrayIcon::~TrayIcon() {
  Remove();
  if (connected_icon_ != nullptr) {
    DestroyIcon(connected_icon_);
    connected_icon_ = nullptr;
  }
  if (idle_icon_ != nullptr) {
    DestroyIcon(idle_icon_);
    idle_icon_ = nullptr;
  }
  if (owner_ != nullptr) {
    // The owner window outlives this object; do not touch it here.
    owner_ = nullptr;
  }
}

HICON TrayIcon::CreateStatusIcon(COLORREF fill, COLORREF ring) {
  BITMAPV5HEADER header = {};
  header.bV5Size = sizeof(header);
  header.bV5Width = kIconSize;
  header.bV5Height = -kIconSize;  // top-down
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5RedMask = 0x00FF0000;
  header.bV5GreenMask = 0x0000FF00;
  header.bV5BlueMask = 0x000000FF;
  header.bV5AlphaMask = 0xFF000000;

  HDC screen = GetDC(nullptr);
  void* bits = nullptr;
  HBITMAP color_bitmap = CreateDIBSection(
      screen, reinterpret_cast<BITMAPINFO*>(&header), DIB_RGB_COLORS, &bits,
      nullptr, 0);
  ReleaseDC(nullptr, screen);
  if (color_bitmap == nullptr || bits == nullptr) {
    if (color_bitmap != nullptr) {
      DeleteObject(color_bitmap);
    }
    return nullptr;
  }

  auto* pixels = static_cast<DWORD*>(bits);
  const int center = kIconSize / 2;
  const int radius = center - 3;
  const int ring_inner = radius - 4;
  for (int y = 0; y < kIconSize; y++) {
    for (int x = 0; x < kIconSize; x++) {
      const int dx = x - center;
      const int dy = y - center;
      const int distance = dx * dx + dy * dy;
      DWORD value = 0;  // fully transparent
      if (distance <= radius * radius) {
        const COLORREF color = distance >= ring_inner * ring_inner ? ring : fill;
        // COLORREF is 0x00BBGGRR; the DIB wants BGRA.
        value = 0xFF000000u | (static_cast<DWORD>(GetBValue(color)) << 16) |
                (static_cast<DWORD>(GetGValue(color)) << 8) |
                static_cast<DWORD>(GetRValue(color));
      }
      pixels[y * kIconSize + x] = value;
    }
  }

  HBITMAP mask = CreateBitmap(kIconSize, kIconSize, 1, 1, nullptr);
  ICONINFO info = {};
  info.fIcon = TRUE;
  info.hbmColor = color_bitmap;
  info.hbmMask = mask;
  HICON icon = CreateIconIndirect(&info);

  DeleteObject(color_bitmap);
  if (mask != nullptr) {
    DeleteObject(mask);
  }
  return icon;
}

bool TrayIcon::Install(HWND owner) {
  if (installed_) {
    return true;
  }
  if (owner == nullptr) {
    return false;
  }
  owner_ = owner;

  data_ = {};
  data_.cbSize = sizeof(NOTIFYICONDATAW);
  data_.hWnd = owner_;
  data_.uID = kTrayIconId;
  data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data_.uCallbackMessage = kCallbackMessage;
  data_.hIcon = connected_ ? connected_icon_ : idle_icon_;
  wcscpy_s(data_.szTip, ARRAYSIZE(data_.szTip), tooltip_.c_str());

  if (Shell_NotifyIconW(NIM_ADD, &data_) == FALSE) {
    data_.hWnd = nullptr;
    return false;
  }
  // Required on Windows 10+ for the callback to deliver mouse messages instead
  // of the legacy "click = default action" behaviour.
  data_.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &data_);
  installed_ = true;
  return true;
}

void TrayIcon::Remove() {
  if (!installed_) {
    return;
  }
  Shell_NotifyIconW(NIM_DELETE, &data_);
  installed_ = false;
}

void TrayIcon::Update() {
  if (!installed_) {
    return;
  }
  data_.hIcon = connected_ ? connected_icon_ : idle_icon_;
  data_.uFlags = NIF_ICON | NIF_TIP;
  wcscpy_s(data_.szTip, ARRAYSIZE(data_.szTip), tooltip_.c_str());
  Shell_NotifyIconW(NIM_MODIFY, &data_);
}

void TrayIcon::SetConnected(bool connected) {
  if (connected_ == connected) {
    return;
  }
  connected_ = connected;
  Update();
}

void TrayIcon::SetTooltip(const std::wstring& text) {
  if (tooltip_ == text) {
    return;
  }
  tooltip_ = text;
  Update();
}

}  // namespace screen_cast_windows

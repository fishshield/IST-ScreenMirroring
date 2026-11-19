#include "include/screen_cast_windows/screen_cast_windows_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "screen_cast_windows_plugin.h"

void ScreenCastWindowsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  screen_cast_windows::ScreenCastWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

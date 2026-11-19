# Flutter Windows plugin: owned overlay + D3D11 NV12 renderer.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "screen_cast_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "screen_cast_windows_plugin")

list(APPEND PLUGIN_SOURCES
  "screen_cast_windows_plugin.cpp"
  "screen_cast_windows_plugin.h"
  "native_video_view.cpp"
  "native_video_view.h"
  "d3d11_renderer.cpp"
  "d3d11_renderer.h"
  "hardware_frame_bridge.cpp"
  "hardware_frame_bridge.h"
  "tray_icon.cpp"
  "tray_icon.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/screen_cast_windows/screen_cast_windows_plugin_c_api.h"
  "screen_cast_windows_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

if (MSVC)
  # Sources contain UTF-8 Chinese UI strings (tray menu, tooltips); without this
  # MSVC reads them as the system code page and the literals fail to compile.
  target_compile_options(${PLUGIN_NAME} PRIVATE /utf-8)
endif()

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  d3d11
  dxgi
  d3dcompiler
  shell32
)

# Intentionally empty; FFmpeg DLLs are copied by the runner CMake install rules
# when third_party/ffmpeg/bin is present.
set(screen_cast_windows_bundled_libraries
  ""
  PARENT_SCOPE
)

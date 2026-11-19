// MethodChannel constants for the native Win32 overlay plugin.
//
// Flutter does not currently expose Android-style PlatformView embedding on
// Windows. This plugin instead creates an owned top-level overlay window; the
// Dart side keeps its bounds in sync with a widget and uploads NV12 frames
// through native-mapped memory. Do not present it as a true PlatformView.

/// Channel used to create, size, show, upload frames to, and dispose the native
/// overlay.
const String screenCastWindowsChannelName = 'dev.screencast/windows_view';

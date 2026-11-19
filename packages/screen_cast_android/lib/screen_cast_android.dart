// Dart-side constants for the Android screen-cast bridge.
//
// The plugin implementation is deliberately thin: it exposes lifecycle and
// texture entry points only. The capture process itself must be launched by
// host ADB. See the package README.

/// MethodChannel shared by the Flutter app and `ScreenCastAndroidPlugin`.
const String screenCastChannelName = 'dev.screencast/control';

/// Default device-side TCP port for the SCRC stream.
const int screenCastDefaultPort = 27183;

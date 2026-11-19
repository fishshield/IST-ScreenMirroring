import 'dart:convert';
import 'dart:io';

/// Desktop settings persisted to `%APPDATA%\ScreenCast\config.json`.
class AppConfig {
  const AppConfig({this.limit60Fps = false});

  /// "限制 60 帧" switch. Off by default.
  final bool limit60Fps;

  AppConfig copyWith({bool? limit60Fps}) =>
      AppConfig(limit60Fps: limit60Fps ?? this.limit60Fps);

  Map<String, Object?> toJson() => <String, Object?>{
        'limit60Fps': limit60Fps,
      };

  /// Tolerant parser: unknown or malformed values fall back to defaults.
  static AppConfig fromJson(Object? decoded) {
    if (decoded is! Map) {
      return const AppConfig();
    }
    final raw = decoded['limit60Fps'];
    return AppConfig(limit60Fps: raw is bool ? raw : false);
  }

  @override
  bool operator ==(Object other) =>
      other is AppConfig && other.limit60Fps == limit60Fps;

  @override
  int get hashCode => limit60Fps.hashCode;
}

/// Loads/saves [AppConfig]; injected in tests with a temporary [File].
class AppConfigStore {
  AppConfigStore({File? file}) : _file = file ?? defaultFile();

  final File _file;

  File get file => _file;

  /// `%APPDATA%\ScreenCast\config.json` on Windows.
  ///
  /// Falls back to the system temp directory when APPDATA is unavailable, so
  /// the app never crashes because of a missing profile directory.
  static File defaultFile() {
    final appData = Platform.environment['APPDATA'];
    final base = (appData != null && appData.isNotEmpty)
        ? appData
        : Directory.systemTemp.path;
    return File(
      <String>[base, 'ScreenCast', 'config.json']
          .join(Platform.pathSeparator),
    );
  }

  Future<AppConfig> load() async {
    try {
      if (!await _file.exists()) {
        return const AppConfig();
      }
      final text = await _file.readAsString();
      if (text.trim().isEmpty) {
        return const AppConfig();
      }
      return AppConfig.fromJson(jsonDecode(text));
    } catch (_) {
      // A broken or unreadable config must never block the app.
      return const AppConfig();
    }
  }

  Future<void> save(AppConfig config) async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(config.toJson()),
      );
    } catch (_) {
      // Persisting the preference is best effort.
    }
  }
}

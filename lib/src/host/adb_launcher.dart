import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../transport/cast_transport.dart';
import 'adb_forward.dart';

class AdbException implements Exception {
  const AdbException(this.message);

  final String message;

  @override
  String toString() => 'AdbException: $message';
}

class AdbLaunchSession {
  AdbLaunchSession({
    required this.adbPath,
    required this.serial,
    required this.port,
    required this.controlPort,
    required this.remoteJarPath,
    required this.process,
    required this.tempDirectory,
    required this.logs,
    required this.transport,
    this.forwards,
    this.usbSerial,
  });

  final String adbPath;

  /// Serial used for the live server shell. In wireless mode this is the TCP
  /// serial (`phone-ip:5555`), so it survives USB removal.
  final String serial;

  final int port;

  /// Input-injection channel; forwarded only in wired mode.
  final int controlPort;

  final String remoteJarPath;

  /// Local adb client process for the attached server shell. In wireless mode
  /// this shell runs over ADB/TCP rather than USB.
  final Process process;

  final Directory tempDirectory;
  final CastTransportConfig transport;

  /// Tunnels this session installed (wired only). Removing them is idempotent
  /// and always attempts every entry, see [AdbForwards.remove].
  final AdbForwards? forwards;

  /// True when this session installed at least one `adb forward`.
  bool get forwarded => forwards?.isNotEmpty ?? false;

  /// USB serial used to switch adbd into TCP mode; restored to USB on stop.
  final String? usbSerial;

  /// Recent stdout/stderr lines from the adb shell process, useful when the
  /// remote server fails before printing its listening banner.
  final List<String> logs;

  String get endpoint => transport.endpoint;
  String get bindAddress => transport.bindAddress;
}

/// Launches the Java capture server on an Android device through host ADB.
///
/// This is the topology-A launch path: the Flutter process stays on Windows,
/// pushes the prebuilt classes.dex jar, optionally installs a TCP forward, then
/// starts `app_process` in an adb shell. Wired mode uses the local forward;
/// wireless mode binds the server on all interfaces and skips the forward.
/// No Android app-side elevation is involved.
class AdbLauncher {
  AdbLauncher({
    String? adbPath,
    this.port = 27183,
    CastTransportMode transportMode = CastTransportMode.wired,
    String targetHost = '',
    int targetFps = 0,
    String? serial,
    CastTransportConfig? transport,
    this.remoteJarPath = '/data/local/tmp/screencast-server.jar',
    this.serverJarLoader,
    this.onLog,
  })  : _adbPath = adbPath,
        _transport = transport ??
            CastTransportConfig(
              mode: transportMode,
              host: targetHost,
              port: port,
              targetFps: targetFps,
              serial: serial,
            );

  static const String serverJarAssetPath =
      'assets/server/screencast-server.jar';
  static const String serverClassName = 'com.example.screencast.server.Server';
  static const int wirelessAdbPort = 5555;

  final String? _adbPath;
  final int port;
  final CastTransportConfig _transport;
  final String remoteJarPath;
  final Future<Uint8List> Function()? serverJarLoader;
  final void Function(String line)? onLog;

  CastTransportConfig get transport => _transport;

  /// The shell command used to start the Java server. Exposed for diagnostics
  /// and tests so the bind address can be checked without launching adb.
  String get serverShellCommand {
    final target = _transport.targetFps;
    final targetArgument = target > 0 ? ' --target-fps=$target' : '';
    return 'CLASSPATH=$remoteJarPath app_process /system/bin '
        '$serverClassName --port=$port '
        '--bind-address=${_transport.bindAddress}$targetArgument';
  }

  AdbLaunchSession? _activeSession;

  /// Tunnels this launcher would install for [serial].
  ///
  /// Wired mode owns two: the SCRC video port and the input-injection control
  /// port. Wireless/direct modes own none. Exposed for diagnostics and tests.
  AdbForwards forwardPlanFor(String serial) =>
      AdbForwards.forConfig(serial: serial, transport: _transport);

  Future<AdbLaunchSession> start({String? serial}) async {
    if (port < 1024 || port > 65535) {
      throw AdbException('Invalid TCP port $port.');
    }
    try {
      _transport.validate();
    } on ArgumentError catch (error) {
      throw AdbException(
        error.message?.toString() ?? 'Invalid transport configuration.',
      );
    }

    if (_activeSession != null) {
      await stop(_activeSession!);
    }

    final executable = await resolveAdbPath();
    final selectedSerial =
        await _selectDevice(executable, serial ?? _transport.serial);
    final forwards = forwardPlanFor(selectedSerial);
    final tempDirectory = await Directory.systemTemp.createTemp(
      'screen_cast_demo_',
    );
    Process? process;
    _ProcessLogPump? logPump;
    var activeSerial = selectedSerial;
    String? usbSerialForRestore;

    try {
      final jarFile = File(
        p.join(tempDirectory.path, 'screencast-server.jar'),
      );
      await jarFile.writeAsBytes(await _loadServerJar(), flush: true);

      await _run(
        executable,
        <String>[
          '-s',
          selectedSerial,
          'push',
          jarFile.path,
          remoteJarPath,
        ],
        'adb push',
      );

      if (!_transport.usesAdbForward) {
        usbSerialForRestore = selectedSerial;
        activeSerial = await _connectTcpAdb(executable, selectedSerial);
      }

      process = await Process.start(
        executable,
        <String>[
          '-s',
          activeSerial,
          'shell',
          serverShellCommand,
        ],
        runInShell: false,
      );

      final logs = <String>[];
      final ready = Completer<void>();
      logPump = _ProcessLogPump(
        process: process,
        logs: logs,
        onLine: (String line) {
          onLog?.call(line);
          if (!ready.isCompleted && line.contains('SCRC server listening')) {
            ready.complete();
          }
        },
      );
      logPump.start();

      unawaited(
        process.exitCode.then((int code) {
          if (!ready.isCompleted) {
            ready.completeError(
              AdbException(
                'app_process exited with code $code before becoming ready. '
                '${_formatLogs(logs)}',
              ),
            );
          }
        }),
      );

      try {
        await ready.future.timeout(const Duration(seconds: 6));
      } on TimeoutException {
        throw AdbException(
          'Timed out waiting for the capture server to listen. '
          '${_formatLogs(logs)}',
        );
      }

      // The desktop (not the controller app) started this server, so the phone
      // app still believes it is idle and its Quick Settings tile never changes.
      // Tell it over ADB; the receiver also asks SystemUI to rebind the tile.
      await _notifyControllerState(executable, activeSerial, started: true);

      // Wired mode tunnels the device-loopback listeners through adb forward:
      // 27183 for SCRC video and 27184 for input injection. Wireless mode
      // intentionally installs no forward: the server binds 0.0.0.0 and the
      // host connects directly to the phone's LAN address.
      if (forwards.isNotEmpty) {
        final installed = await forwards.install(
          (List<String> arguments) =>
              _run(executable, arguments, 'adb forward'),
        );
        final videoTunnel = forwards.videoTunnel;
        if (videoTunnel != null && !installed.contains(videoTunnel)) {
          // Without the video tunnel the session is unusable; the catch block
          // still removes every planned tunnel.
          throw AdbException(
            'Could not install adb forward ${videoTunnel.label}. '
            '${_formatForwardFailures(installed.failures)}',
          );
        }
        // The control tunnel is best-effort: losing it only disables input
        // injection, so the video session still starts.
        if (installed.failures.isNotEmpty) {
          onLog?.call(
            'Control forward unavailable; input injection will stay '
            'disconnected: ${_formatForwardFailures(installed.failures)}',
          );
        }
      }

      final session = AdbLaunchSession(
        adbPath: executable,
        serial: activeSerial,
        port: port,
        controlPort: _transport.controlPort,
        remoteJarPath: remoteJarPath,
        process: process,
        tempDirectory: tempDirectory,
        logs: logs,
        transport: _transport,
        forwards: forwards.isNotEmpty ? forwards : null,
        usbSerial: usbSerialForRestore,
      );
      _activeSession = session;
      onLog?.call(
        forwards.isNotEmpty
            ? 'ADB ready on $activeSerial; forwarding '
                '${forwards.tunnels.map((AdbForward tunnel) => tunnel.label).join(', ')}'
            : 'ADB/TCP ready on $activeSerial; LAN direct '
                '${_transport.endpoint}, no adb forward',
      );
      return session;
    } catch (error) {
      logPump?.stop();
      if (process != null) {
        process.kill();
      }
      if (forwards.isNotEmpty) {
        // Idempotent cleanup: every planned tunnel is attempted, and a single
        // failure (already removed / device gone) never skips the others.
        final removed = await forwards.remove(
          (List<String> arguments) =>
              _run(executable, arguments, 'adb forward --remove'),
        );
        for (final failure in removed.failures) {
          onLog?.call('adb forward cleanup failed: $failure');
        }
      } else {
        await _bestEffort(
          executable,
          <String>[
            '-s',
            activeSerial,
            'shell',
            'pkill -f $serverClassName',
          ],
        );
        if (usbSerialForRestore != null) {
          await _bestEffort(
            executable,
            <String>['-s', activeSerial, 'usb'],
          );
        }
      }
      await _deleteDirectory(tempDirectory);
      if (error is AdbException) {
        rethrow;
      }
      throw AdbException('Failed to launch capture server: $error');
    }
  }

  /// Starts the server over an already-connected ADB/TCP transport without
  /// touching USB or pushing the jar again. Used when USB disappears after the
  /// initial wireless setup and the app needs to restart the capture server.
  Future<AdbLaunchSession> startExistingWireless(String tcpSerial) async {
    _transport.validate();
    if (_transport.usesAdbForward) {
      throw const AdbException(
        'startExistingWireless is only valid for wireless mode.',
      );
    }

    final executable = await resolveAdbPath();
    final tempDirectory = await Directory.systemTemp.createTemp(
      'screen_cast_recover_',
    );
    Process? process;
    _ProcessLogPump? logPump;

    try {
      process = await Process.start(
        executable,
        <String>[
          '-s',
          tcpSerial,
          'shell',
          serverShellCommand,
        ],
        runInShell: false,
      );

      final logs = <String>[];
      final ready = Completer<void>();
      logPump = _ProcessLogPump(
        process: process,
        logs: logs,
        onLine: (String line) {
          onLog?.call(line);
          if (!ready.isCompleted && line.contains('SCRC server listening')) {
            ready.complete();
          }
        },
      );
      logPump.start();

      unawaited(
        process.exitCode.then((int code) {
          if (!ready.isCompleted) {
            ready.completeError(
              AdbException(
                'app_process exited with code $code during wireless recovery. '
                '${_formatLogs(logs)}',
              ),
            );
          }
        }),
      );

      try {
        await ready.future.timeout(const Duration(seconds: 6));
      } on TimeoutException {
        throw AdbException(
          'Timed out waiting for the capture server during wireless recovery. '
          '${_formatLogs(logs)}',
        );
      }

      final session = AdbLaunchSession(
        adbPath: executable,
        serial: tcpSerial,
        port: port,
        remoteJarPath: remoteJarPath,
        process: process,
        tempDirectory: tempDirectory,
        logs: logs,
        transport: _transport,
        forwards: null,
        controlPort: _transport.controlPort,
        usbSerial: null,
      );
      _activeSession = session;
      onLog?.call(
        'Wireless recovery server listening via ADB/TCP $tcpSerial; '
        'LAN ${_transport.endpoint}, no adb forward',
      );
      return session;
    } catch (error) {
      logPump?.stop();
      process?.kill();
      await _deleteDirectory(tempDirectory);
      if (error is AdbException) {
        rethrow;
      }
      throw AdbException('Wireless recovery launch failed: $error');
    }
  }

  Future<String> _connectTcpAdb(
    String executable,
    String usbSerial,
  ) async {
    final host = _transport.effectiveHost;
    final formattedHost = host.contains(':') ? '[$host]' : host;
    final tcpSerial = '$formattedHost:$wirelessAdbPort';

    await _run(
      executable,
      <String>[
        '-s',
        usbSerial,
        'tcpip',
        '$wirelessAdbPort',
      ],
      'adb tcpip',
    );

    final deadline = DateTime.now().add(const Duration(seconds: 12));
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final connect = await Process.run(
          executable,
          <String>['connect', tcpSerial],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        final state = await Process.run(
          executable,
          <String>['-s', tcpSerial, 'get-state'],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        if (state.exitCode == 0 && '${state.stdout}'.trim() == 'device') {
          onLog?.call('ADB/TCP connected: $tcpSerial');
          return tcpSerial;
        }
        lastError = 'connect=${connect.stdout}${connect.stderr} '
            'state=${state.stdout}${state.stderr}';
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    throw AdbException(
      'Could not establish ADB over TCP at $tcpSerial. '
      'Ensure phone and Windows are on the same LAN and ADB port '
      '$wirelessAdbPort is reachable. ${lastError ?? ''}',
    );
  }

  Future<void> stop(
    AdbLaunchSession session, {
    bool restoreUsb = true,
  }) async {
    if (identical(_activeSession, session)) {
      _activeSession = null;
    }

    // pkill is the only reliable way to stop the remote app_process; killing
    // the local adb client alone can leave the device-side server running.
    await _bestEffort(
      session.adbPath,
      <String>[
        '-s',
        session.serial,
        'shell',
        'pkill -f $serverClassName',
      ],
    );
    // Mirror the stop into the phone app so its tile does not keep claiming a
    // running session (best effort: the app may not be installed).
    await _notifyControllerState(
      session.adbPath,
      session.serial,
      started: false,
    );
    final forwards = session.forwards;
    if (forwards != null && forwards.isNotEmpty) {
      // Idempotent: both tunnels are attempted even if the first `--remove`
      // fails (already gone, device unplugged), and a single failure is logged
      // instead of aborting the remaining cleanup.
      final removed = await forwards.remove(
        (List<String> arguments) =>
            _run(session.adbPath, arguments, 'adb forward --remove'),
      );
      for (final failure in removed.failures) {
        onLog?.call('adb forward cleanup skipped: $failure');
      }
    }
    if (restoreUsb &&
        session.usbSerial != null &&
        await _devicePresent(session.adbPath, session.usbSerial!)) {
      // Best effort: switch adbd back to USB mode after stopping the server.
      // This closes the temporary ADB/TCP transport used by wireless mode.
      await _bestEffort(
        session.adbPath,
        <String>['-s', session.serial, 'usb'],
      );
      await _bestEffort(
        session.adbPath,
        <String>['disconnect', session.serial],
      );
    }

    session.process.kill();
    await _deleteDirectory(session.tempDirectory);
  }

  Future<bool> _devicePresent(String executable, String serial) async {
    try {
      final output = await _run(executable, <String>['devices'], 'adb devices');
      return parseDeviceSerials(output).contains(serial);
    } catch (_) {
      return false;
    }
  }

  Future<String> resolveAdbPath() async {
    final explicit = _adbPath ?? Platform.environment['ADB'];
    if (explicit != null && explicit.isNotEmpty) {
      if (!await _probe(explicit)) {
        throw AdbException('ADB executable is not runnable: $explicit');
      }
      return explicit;
    }

    final executable = Platform.isWindows ? 'adb.exe' : 'adb';
    final sdkRoots = <String?>[
      Platform.environment['ANDROID_HOME'],
      Platform.environment['ANDROID_SDK_ROOT'],
      Platform.isWindows
          ? p.join(
              Platform.environment['LOCALAPPDATA'] ?? '',
              'Android',
              'Sdk',
            )
          : null,
      if (!Platform.isWindows)
        p.join(Platform.environment['HOME'] ?? '', 'Library/Android/sdk'),
      if (!Platform.isWindows)
        p.join(Platform.environment['HOME'] ?? '', 'Android/Sdk'),
    ];

    for (final root in sdkRoots) {
      if (root == null || root.isEmpty) {
        continue;
      }
      final candidate = p.join(root, 'platform-tools', executable);
      if (await _probe(candidate)) {
        return candidate;
      }
    }

    // Finally, let the OS resolve `adb` from PATH.
    if (await _probe(executable)) {
      return executable;
    }

    throw const AdbException(
      'ADB was not found. Install Android platform-tools, add adb to PATH, '
      'or set the ADB environment variable.',
    );
  }

  static List<String> parseDeviceSerials(String devicesOutput) {
    final serials = <String>[];
    for (final rawLine in devicesOutput.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty ||
          line.startsWith('List of devices') ||
          line.startsWith('* daemon')) {
        continue;
      }
      final fields = line.split(RegExp(r'\s+'));
      if (fields.length >= 2 && fields[1] == 'device') {
        serials.add(fields.first);
      }
    }
    return serials;
  }

  Future<String> _selectDevice(String executable, String? requested) async {
    final output = await _run(
      executable,
      <String>['devices'],
      'adb devices',
    );
    final serials = parseDeviceSerials(output);
    final serial = requested;
    if (serial != null && serial.isNotEmpty) {
      if (!serials.contains(serial)) {
        throw AdbException(
          'Requested device "$serial" is not available. '
          '${_formatDevices(serials)}',
        );
      }
      return serial;
    }

    if (serials.isEmpty) {
      throw AdbException(
        'No Android device is authorized. Enable USB debugging and accept '
        'the RSA prompt. ${_formatDevices(serials)}',
      );
    }
    if (serials.length > 1) {
      throw AdbException(
        'More than one Android device is connected; specify a serial. '
        '${_formatDevices(serials)}',
      );
    }
    return serials.single;
  }

  Future<Uint8List> _loadServerJar() async {
    final loader = serverJarLoader;
    if (loader != null) {
      return loader();
    }
    final data = await rootBundle.load(serverJarAssetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<bool> _probe(String executable) async {
    try {
      final result = await Process.run(
        executable,
        <String>['version'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  Future<String> _run(
    String executable,
    List<String> arguments,
    String stage,
  ) async {
    try {
      final result = await Process.run(
        executable,
        arguments,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final output = '${result.stdout}${result.stderr}'.trim();
      if (result.exitCode != 0) {
        throw AdbException(
          '$stage failed with exit code ${result.exitCode}.'
          '${output.isEmpty ? '' : '\n$output'}',
        );
      }
      return output;
    } on ProcessException catch (error) {
      throw AdbException('$stage failed: ${error.message}');
    }
  }

  /// Tells the phone app that a desktop-started session began or ended.
  ///
  /// The app's Quick Settings tile is drawn from its own state store, which the
  /// desktop otherwise never updates: without this the tile kept saying
  /// "已停止" after a wireless auto-connect. Best effort — the app may not be
  /// installed, and a failed broadcast must not fail the session.
  Future<void> _notifyControllerState(
    String adb,
    String serial, {
    required bool started,
  }) async {
    final action = started
        ? 'com.example.screencast.action.SERVER_STARTED'
        : 'com.example.screencast.action.SERVER_STOPPED';
    await _bestEffort(adb, <String>[
      '-s',
      serial,
      'shell',
      'am',
      'broadcast',
      '-a',
      action,
      '-n',
      'com.example.screencast.controller/.CastStateReceiver',
    ]);
  }

  Future<void> _bestEffort(String executable, List<String> arguments) async {
    try {
      await Process.run(
        executable,
        arguments,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } catch (_) {
      // Best effort only: physical device disconnects are expected here.
    }
  }

  Future<void> _deleteDirectory(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // A leftover temporary jar is harmless; do not mask the launch result.
    }
  }

  String _formatDevices(List<String> serials) {
    return serials.isEmpty ? 'Found: none.' : 'Found: ${serials.join(', ')}.';
  }

  String _formatForwardFailures(List<AdbForwardFailure> failures) {
    if (failures.isEmpty) {
      return 'No adb forward error output.';
    }
    return failures.map((AdbForwardFailure f) => '$f').join('; ');
  }

  String _formatLogs(List<String> logs) {
    if (logs.isEmpty) {
      return 'No adb shell output.';
    }
    return 'Last adb shell output:\n${logs.join('\n')}';
  }
}

class _ProcessLogPump {
  _ProcessLogPump({
    required this.process,
    required this.logs,
    required this.onLine,
  });

  final Process process;
  final List<String> logs;
  final void Function(String line) onLine;

  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  void start() {
    _stdoutSubscription = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_handleLine);
    _stderrSubscription = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_handleLine);
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    logs.add(line);
    if (logs.length > 40) {
      logs.removeAt(0);
    }
    onLine(line);
  }

  void stop() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
  }
}

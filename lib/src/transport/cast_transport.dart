import 'package:flutter/foundation.dart';

import '../crypto/psk_cipher.dart';

/// How the Windows host reaches the capture SCRC socket.
enum CastTransportMode {
  /// ADB forward over the USB tunnel; the Java server binds loopback.
  wired,

  /// The desktop starts the server over ADB/TCP, then talks to the phone's LAN
  /// address directly; no `adb forward` is installed.
  wireless,

  /// Nothing is pushed or started from the desktop. The Android controller app
  /// (Shizuku) already owns the server process, and the desktop only connects
  /// to `<phone-ip>:27183`.
  direct,
}

extension CastTransportModePresentation on CastTransportMode {
  String get label {
    switch (this) {
      case CastTransportMode.wired:
        return '有线 ADB';
      case CastTransportMode.wireless:
        return '无线 ADB';
      case CastTransportMode.direct:
        return 'App 直连';
    }
  }

  /// Short label for the segmented selector.
  String get shortLabel {
    switch (this) {
      case CastTransportMode.wired:
        return '有线';
      case CastTransportMode.wireless:
        return '无线';
      case CastTransportMode.direct:
        return '直连';
    }
  }

  /// One-line explanation shown above the selector.
  String get description {
    switch (this) {
      case CastTransportMode.wired:
        return '通过 ADB 推送服务端 jar，建立端口转发，再以 shell 用户启动 app_process。';
      case CastTransportMode.wireless:
        return '通过 ADB 推送并启动服务端；服务端监听 0.0.0.0，视频流直接连接手机局域网 IP。';
      case CastTransportMode.direct:
        return '不执行任何 ADB 命令：手机上由 Shizuku 控制 App 启动服务端，桌面只连接 <手机IP>:27183。';
    }
  }

  bool get usesAdbForward => this == CastTransportMode.wired;

  /// Whether the desktop is responsible for pushing and starting the server.
  /// [direct] leaves that to the Android controller app.
  bool get startsServerOverAdb => this != CastTransportMode.direct;

  /// Whether the desktop needs a phone LAN address to connect.
  bool get requiresLanHost => this != CastTransportMode.wired;

  String get serverBindAddress =>
      this == CastTransportMode.wired ? '127.0.0.1' : '0.0.0.0';
}

/// Immutable connection settings shared by the launcher, socket client, state
/// and UI.
///
/// In wired mode [host] is intentionally ignored and the client always uses
/// loopback, because the ADB forward owns the tunnel. In wireless and direct
/// modes [host] is the phone's LAN address and must be supplied by the user.
@immutable
class CastTransportConfig {
  const CastTransportConfig({
    this.mode = CastTransportMode.wired,
    this.host = '',
    this.port = 27183,
    this.controlPort = 27184,
    this.pskHex = '',
    this.targetFps = 0,
    this.serial,
  });

  final CastTransportMode mode;
  final String host;
  final int port;

  /// ADB serial selected in the device list; null lets the launcher pick the
  /// only authorized device.
  final String? serial;

  /// Separate input-injection channel; never carries video.
  final int controlPort;

  /// Pre-shared key as hex (32/48/64 chars). Empty means plaintext.
  final String pskHex;

  /// Requested capture rate for the server's `--target-fps` hint.
  ///
  /// 0 disables the hint. It is only passed by the transports that start the
  /// server themselves (wired/wireless); `direct` connects to a server someone
  /// else started.
  final int targetFps;

  String get normalizedHost => host.trim();

  /// Address that the Windows socket client connects to.
  String get effectiveHost =>
      mode == CastTransportMode.wired ? '127.0.0.1' : normalizedHost;

  String get bindAddress => mode.serverBindAddress;

  bool get usesAdbForward => mode.usesAdbForward;

  bool get startsServerOverAdb => mode.startsServerOverAdb;

  bool get requiresLanHost => mode.requiresLanHost;

  bool get hasUsableHost => !mode.requiresLanHost || normalizedHost.isNotEmpty;

  String get displayHost {
    if (mode.requiresLanHost && normalizedHost.isEmpty) {
      return '未填写手机 IP';
    }
    final hostText =
        mode == CastTransportMode.wired ? '127.0.0.1' : normalizedHost;
    final endpointHost = hostText.contains(':') ? '[$hostText]' : hostText;
    return '$endpointHost:$port';
  }

  String get endpoint => displayHost;

  /// Throws [ArgumentError] when the settings cannot form a valid session.
  void validate() {
    if (port < 1024 || port > 65535) {
      throw ArgumentError.value(
        port,
        'port',
        'Must be between 1024 and 65535.',
      );
    }
    if (controlPort < 1024 || controlPort > 65535) {
      throw ArgumentError.value(
        controlPort,
        'controlPort',
        'Must be between 1024 and 65535.',
      );
    }
    if (controlPort == port) {
      throw ArgumentError.value(
        controlPort,
        'controlPort',
        'Control port must differ from the SCRC video port.',
      );
    }
    if (targetFps != 0 && (targetFps < 1 || targetFps > 240)) {
      throw ArgumentError.value(
        targetFps,
        'targetFps',
        'Must be 0 (unlimited) or between 1 and 240.',
      );
    }
    final pskProblem = PskCipher.validateHex(pskHex);
    if (pskProblem != null) {
      throw ArgumentError.value(pskHex, 'pskHex', pskProblem);
    }
    if (mode.requiresLanHost) {
      if (normalizedHost.isEmpty) {
        throw ArgumentError(
          mode == CastTransportMode.direct
              ? 'Direct mode requires the phone LAN IP address.'
              : 'Wireless mode requires the phone LAN IP address.',
        );
      }
      if (RegExp(r'\s').hasMatch(normalizedHost)) {
        throw ArgumentError.value(
          host,
          'host',
          'Phone LAN address must not contain whitespace.',
        );
      }
    }
  }

  CastTransportConfig copyWith({
    CastTransportMode? mode,
    String? host,
    int? port,
    int? controlPort,
    String? pskHex,
    int? targetFps,
    String? serial,
  }) {
    return CastTransportConfig(
      mode: mode ?? this.mode,
      host: host ?? this.host,
      port: port ?? this.port,
      controlPort: controlPort ?? this.controlPort,
      pskHex: pskHex ?? this.pskHex,
      targetFps: targetFps ?? this.targetFps,
      serial: serial ?? this.serial,
    );
  }
}

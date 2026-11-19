import 'package:flutter/foundation.dart';

import '../transport/cast_transport.dart';

enum CastStatus {
  idle,
  starting,
  running,
  stopping,
  error,
}

extension CastStatusPresentation on CastStatus {
  bool get isBusy => this == CastStatus.starting || this == CastStatus.stopping;

  String get label {
    switch (this) {
      case CastStatus.idle:
        return '空闲';
      case CastStatus.starting:
        return '启动中';
      case CastStatus.running:
        return '运行中';
      case CastStatus.stopping:
        return '停止中';
      case CastStatus.error:
        return '异常';
    }
  }
}

/// Input channel state. Deliberately separate from [CastStatus]: losing the
/// control socket must not affect the video session.
enum ControlLinkState {
  idle,
  connecting,
  connected,
  disconnected,
}

extension ControlLinkStatePresentation on ControlLinkState {
  String get label {
    switch (this) {
      case ControlLinkState.idle:
        return '控制未连接';
      case ControlLinkState.connecting:
        return '控制连接中';
      case ControlLinkState.connected:
        return '控制已连接';
      case ControlLinkState.disconnected:
        return '控制已断开';
    }
  }

  bool get isConnected => this == ControlLinkState.connected;
}

@immutable
class CastSessionState {
  const CastSessionState({
    required this.status,
    required this.message,
    required this.port,
    this.controlPort = 27184,
    this.transportMode = CastTransportMode.wired,
    this.host = '',
    this.pskHex = '',
    this.serial,
    this.limit60Fps = false,
    this.autoConnect = false,
    this.discoveryStatus = '',
    this.discoveryError = false,
    this.framesDecoded = 0,
    this.framesUploaded = 0,
    this.framesDropped = 0,
    this.framesPerSecond = 0,
    this.presentFps = 0,
    this.frameWidth = 0,
    this.frameHeight = 0,
    this.adbSerial,
    this.controlLink = ControlLinkState.idle,
  });

  const CastSessionState.initial()
      : status = CastStatus.idle,
        message = '尚未启动投屏会话。',
        port = 27183,
        controlPort = 27184,
        transportMode = CastTransportMode.wired,
        host = '',
        pskHex = '',
        serial = null,
        limit60Fps = false,
        autoConnect = false,
        discoveryStatus = '',
        discoveryError = false,
        framesDecoded = 0,
        framesUploaded = 0,
        framesDropped = 0,
        framesPerSecond = 0,
        presentFps = 0,
        frameWidth = 0,
        frameHeight = 0,
        adbSerial = null,
        controlLink = ControlLinkState.idle;

  final CastStatus status;
  final String message;
  final int port;

  /// Input-injection port; comes from the offer in auto-connect mode.
  final int controlPort;
  final CastTransportMode transportMode;

  /// Phone LAN address used by [CastTransportMode.wireless] and
  /// [CastTransportMode.direct].
  final String host;

  /// Pre-shared key (hex) for the record layer; empty means plaintext.
  final String pskHex;

  /// ADB serial picked in the device list (wired mode only).
  final String? serial;

  /// "限制 60 帧" switch. When on, the desktop passes `--target-fps=60` to the
  /// server it starts (wired/wireless); the server asks the display stack for
  /// that rate and reports whether the hint was honoured.
  final bool limit60Fps;

  /// LAN discovery auto-connect switch (UDP/27185).
  final bool autoConnect;

  /// Last discovery line shown in the control panel ("已发现 …").
  final String discoveryStatus;

  /// True when [discoveryStatus] reports a failure (rendered in red).
  final bool discoveryError;

  final int framesDecoded;

  /// Frames committed to a native staging texture (double-buffered upload).
  final int framesUploaded;

  /// Frames dropped because their predecessor was still being presented.
  final int framesDropped;

  /// Decoded frames in the last one-second window.
  final int framesPerSecond;

  /// Frames actually presented by the native D3D11 swap chain in the last
  /// second. Lower than [framesPerSecond] when the display cannot keep up.
  final int presentFps;

  final int frameWidth;
  final int frameHeight;
  final String? adbSerial;

  /// Input channel state; video keeps running when this is disconnected.
  final ControlLinkState controlLink;

  CastTransportConfig get transport => CastTransportConfig(
        mode: transportMode,
        host: host,
        port: port,
        controlPort: controlPort,
        pskHex: pskHex,
        targetFps: limit60Fps ? 60 : 0,
        serial: serial,
      );

  String get endpoint => transport.endpoint;

  bool get canConfigureTransport =>
      !status.isBusy && status != CastStatus.running;

  bool get canStart =>
      canConfigureTransport &&
      (transportMode == CastTransportMode.wired || host.trim().isNotEmpty);

  bool get canStop =>
      status == CastStatus.running || status == CastStatus.error;

  String? get frameSize {
    if (frameWidth <= 0 || frameHeight <= 0) {
      return null;
    }
    return '${frameWidth}x$frameHeight';
  }

  CastSessionState copyWith({
    CastStatus? status,
    String? message,
    int? port,
    int? controlPort,
    CastTransportMode? transportMode,
    String? host,
    String? pskHex,
    String? serial,
    bool? limit60Fps,
    bool? autoConnect,
    String? discoveryStatus,
    bool? discoveryError,
    int? framesDecoded,
    int? framesUploaded,
    int? framesDropped,
    int? framesPerSecond,
    int? presentFps,
    int? frameWidth,
    int? frameHeight,
    String? adbSerial,
    ControlLinkState? controlLink,
    bool clearFrameCounters = false,
    bool clearAdbSerial = false,
    bool clearSerial = false,
  }) {
    return CastSessionState(
      status: status ?? this.status,
      message: message ?? this.message,
      port: port ?? this.port,
      controlPort: controlPort ?? this.controlPort,
      transportMode: transportMode ?? this.transportMode,
      host: host ?? this.host,
      pskHex: pskHex ?? this.pskHex,
      serial: clearSerial ? null : serial ?? this.serial,
      limit60Fps: limit60Fps ?? this.limit60Fps,
      autoConnect: autoConnect ?? this.autoConnect,
      discoveryStatus: discoveryStatus ?? this.discoveryStatus,
      discoveryError: discoveryError ?? this.discoveryError,
      framesDecoded:
          clearFrameCounters ? 0 : framesDecoded ?? this.framesDecoded,
      framesUploaded:
          clearFrameCounters ? 0 : framesUploaded ?? this.framesUploaded,
      framesDropped:
          clearFrameCounters ? 0 : framesDropped ?? this.framesDropped,
      framesPerSecond:
          clearFrameCounters ? 0 : framesPerSecond ?? this.framesPerSecond,
      presentFps: clearFrameCounters ? 0 : presentFps ?? this.presentFps,
      frameWidth: frameWidth ?? this.frameWidth,
      frameHeight: frameHeight ?? this.frameHeight,
      adbSerial: clearAdbSerial ? null : adbSerial ?? this.adbSerial,
      controlLink: controlLink ?? this.controlLink,
    );
  }
}

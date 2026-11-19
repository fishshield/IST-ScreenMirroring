import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:screen_cast_demo/src/control/control_client.dart';
import 'package:screen_cast_demo/src/control/control_message.dart';
import 'package:screen_cast_demo/src/crypto/psk_cipher.dart';
import 'package:screen_cast_demo/src/ffmpeg/decoded_frame.dart';
import 'package:screen_cast_demo/src/ffmpeg/ffmpeg_decoder.dart';
import 'package:screen_cast_demo/src/host/adb_launcher.dart';
import 'package:screen_cast_demo/src/protocol/scrc_packet.dart';
import 'package:screen_cast_demo/src/transport/cast_transport.dart';
import 'package:screen_cast_demo/src/transport/scrc_socket_client.dart';

import 'nal_decode_queue.dart';

class CastSessionInfo {
  const CastSessionInfo({
    required this.adbPath,
    required this.serial,
    required this.port,
    required this.endpoint,
    required this.transportMode,
    required this.decoderBackend,
  });

  /// Null in [CastTransportMode.direct], where the desktop runs no ADB at all.
  final String? adbPath;

  /// Null in [CastTransportMode.direct]; the serial is unknown because the
  /// server was started by the Android controller app, not by this host.
  final String? serial;

  final int port;
  final String endpoint;
  final CastTransportMode transportMode;
  final String decoderBackend;
}

/// Orchestrates the desktop-side chain:
/// optional ADB launch -> pushed classes.dex -> optional TCP forward ->
/// SCRC socket -> NAL queue -> FFmpeg decode.
///
/// In [CastTransportMode.direct] the ADB half is skipped entirely: the server
/// already runs on the phone (started by the Android controller app through
/// Shizuku) and the session only owns the socket and the decoder.
class CastSession {
  factory CastSession({
    int port = 27183,
    CastTransportMode transportMode = CastTransportMode.wired,
    String host = '',
    CastTransportConfig? transport,
    String? existingTcpSerial,
    AdbLauncher? launcher,
    ScrcSocketClient? socketClient,
    FfmpegDecoder Function()? decoderFactory,
  }) {
    final config = transport ??
        CastTransportConfig(
          mode: transportMode,
          host: host,
          port: port,
        );
    return CastSession._(
      transport: config,
      existingTcpSerial: existingTcpSerial,
      launcher: launcher,
      socketClient: socketClient,
      decoderFactory: decoderFactory,
    );
  }

  CastSession._({
    required this.transport,
    String? existingTcpSerial,
    AdbLauncher? launcher,
    ScrcSocketClient? socketClient,
    FfmpegDecoder Function()? decoderFactory,
  })  : _existingTcpSerial = existingTcpSerial,
        _cipher = PskCipher.fromHex(transport.pskHex),
        _launcher = transport.startsServerOverAdb
            ? (launcher ?? AdbLauncher(transport: transport))
            : launcher,
        _socketClientOverride = socketClient,
        _decoderFactory = decoderFactory ?? FfmpegDecoder.open;

  final CastTransportConfig transport;
  final String? _existingTcpSerial;

  /// Record-layer key shared by the SCRC and control clients; null = plaintext.
  /// Both protocols sit above it unchanged.
  final PskCipher? _cipher;

  final ScrcSocketClient? _socketClientOverride;
  ScrcSocketClient? _socketClientInstance;

  ScrcSocketClient get _socketClient {
    final existing = _socketClientInstance;
    if (existing != null) {
      return existing;
    }
    final client = _socketClientOverride ??
        ScrcSocketClient(
          host: transport.effectiveHost,
          port: transport.port,
          cipher: _cipher,
        );
    _socketClientInstance = client;
    return client;
  }

  /// Null in direct mode: this host never pushes or starts anything.
  final AdbLauncher? _launcher;
  final FfmpegDecoder Function() _decoderFactory;
  final NalDecodeQueue _queue = NalDecodeQueue();

  AdbLaunchSession? _adbSession;
  ScrcConnection? _connection;
  StreamSubscription<ScrcPacket>? _socketSubscription;
  FfmpegDecoder? _decoder;
  Future<void>? _decodeTask;
  ControlClient? _control;
  bool _controlConnected = false;

  void Function(Object error, StackTrace stackTrace)? _onError;
  void Function()? _onClosed;
  void Function(bool connected)? _onControlState;
  FutureOr<void> Function(DecodedFrame frame)? _onFrame;

  bool _started = false;
  bool _stopping = false;
  bool _ended = false;
  bool _errorReported = false;
  int _framesDecoded = 0;

  int get framesDecoded => _framesDecoded;

  bool get controlConnected => _controlConnected;

  Future<CastSessionInfo> start({
    FutureOr<void> Function(DecodedFrame frame)? onFrame,
    void Function(Object error, StackTrace stackTrace)? onError,
    void Function()? onClosed,
    void Function(bool connected)? onControlState,
  }) async {
    if (_started) {
      throw StateError('CastSession.start may only be called once.');
    }
    _started = true;
    _onFrame = onFrame;
    _onError = onError;
    _onClosed = onClosed;
    _onControlState = onControlState;

    transport.validate();

    AdbLaunchSession? adbSession;
    try {
      if (transport.startsServerOverAdb) {
        final launcher = _launcher;
        if (launcher == null) {
          throw StateError('ADB launcher is unavailable for ${transport.mode}.');
        }
        final existingTcpSerial = _existingTcpSerial;
        adbSession = existingTcpSerial == null
            ? await launcher.start()
            : await launcher.startExistingWireless(existingTcpSerial);
        _adbSession = adbSession;
      }

      // Open the decoder before consuming the single socket connection.
      final decoder = _decoderFactory();
      _decoder = decoder;

      final connection = await _socketClient.connectWithRetry();
      _connection = connection;
      _socketSubscription = connection.packets.listen(
        (ScrcPacket packet) {
          _queue.add(packet.payload);
        },
        onError: (Object error, StackTrace stackTrace) {
          _reportError(error, stackTrace);
        },
        onDone: _handleConnectionDone,
        cancelOnError: false,
      );
      _decodeTask = _decodeLoop();

      // The control channel is best-effort: a failure only disables input and
      // must never abort the video session.
      _control = ControlClient(
        host: transport.effectiveHost,
        port: transport.controlPort,
        cipher: _cipher,
      )..onDisconnected = _handleControlDisconnected;
      unawaited(_connectControl());

      return CastSessionInfo(
        adbPath: adbSession?.adbPath,
        serial: adbSession?.serial,
        port: transport.port,
        endpoint: transport.endpoint,
        transportMode: transport.mode,
        decoderBackend: 'FFmpeg avcodec',
      );
    } catch (error, stackTrace) {
      await _cleanupAfterFailedStart();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Asks the decoder to re-measure the letterbox content rect on the next
  /// frame (used when the video window is resized by the user).
  void requestContentProbe() {
    _decoder?.requestContentProbe();
  }

  Future<void> _decodeLoop() async {
    final decoder = _decoder;
    if (decoder == null) {
      return;
    }

    while (true) {
      final nal = await _queue.take();
      if (nal == null) {
        break;
      }

      try {
        final frames = decoder.decode(nal);
        for (final frame in frames) {
          if (_stopping) {
            return;
          }
          _framesDecoded++;
          await _onFrame?.call(frame);
        }
      } catch (error, stackTrace) {
        _reportError(error, stackTrace);
        _queue.close();
        return;
      }
    }
  }

  void _handleConnectionDone() {
    if (_stopping || _ended) {
      return;
    }
    _ended = true;
    _queue.close();
    // A record-layer failure closes the socket right after reporting itself;
    // keep that (actionable) error instead of overwriting it with "closed".
    if (_errorReported) {
      return;
    }
    _onClosed?.call();
  }

  Future<void> _connectControl() async {
    final control = _control;
    if (control == null) {
      return;
    }
    try {
      await control.connect();
      if (_stopping || _ended) {
        await control.close();
        return;
      }
      _controlConnected = true;
      _onControlState?.call(true);
    } catch (error) {
      _controlConnected = false;
      _onControlState?.call(false);
      debugPrint('Control channel unavailable: $error');
    }
  }

  void _handleControlDisconnected() {
    if (!_controlConnected) {
      return;
    }
    _controlConnected = false;
    _onControlState?.call(false);
  }

  /// Sends one input frame; returns false when the control link is gone.
  bool sendControl(ControlMessage message) {
    final control = _control;
    if (control == null) {
      return false;
    }
    return control.send(message);
  }

  void _reportError(Object error, StackTrace stackTrace) {
    if (_ended && !_stopping) {
      return;
    }
    _errorReported = true;
    _onError?.call(error, stackTrace);
  }

  Future<void> stop({bool restoreUsb = true}) async {
    if (_stopping) {
      return;
    }
    _stopping = true;
    _ended = true;
    _queue.close();

    final control = _control;
    _control = null;
    _controlConnected = false;
    await control?.close();

    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _connection?.close();
    _connection = null;

    final decodeTask = _decodeTask;
    if (decodeTask != null) {
      await decodeTask;
    }
    _decodeTask = null;

    _decoder?.dispose();
    _decoder = null;

    final adbSession = _adbSession;
    _adbSession = null;
    if (adbSession != null) {
      await _launcher?.stop(adbSession, restoreUsb: restoreUsb);
    }
    _cipher?.dispose();
    _stopping = false;
  }

  Future<void> _cleanupAfterFailedStart() async {
    _queue.close();
    final control = _control;
    _control = null;
    _controlConnected = false;
    await control?.close();
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _connection?.close();
    _connection = null;
    _decoder?.dispose();
    _decoder = null;
    final adbSession = _adbSession;
    _adbSession = null;
    if (adbSession != null) {
      await _launcher?.stop(adbSession);
    }
    _cipher?.dispose();
    _ended = true;
  }
}

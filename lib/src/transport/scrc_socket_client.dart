import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:screen_cast_demo/src/crypto/psk_cipher.dart';
import 'package:screen_cast_demo/src/protocol/scrc_packet.dart';
import 'package:screen_cast_demo/src/protocol/scrc_packet_decoder.dart';
import 'package:screen_cast_demo/src/transport/secure_channel.dart';
import 'package:screen_cast_demo/src/transport/transport.dart';

class ScrcConnectionException implements Exception {
  const ScrcConnectionException(this.message);

  final String message;

  @override
  String toString() => 'ScrcConnectionException: $message';
}

/// TCP client for the SCRC stream.
///
/// Wired mode connects to the local end of `adb forward` (127.0.0.1). Wireless
/// mode connects directly to the phone's LAN address and does not require a
/// forward.
///
/// Bytes travel through a [SecureChannel]; the SCRC framing above it is
/// untouched. With a null [cipher] the channel is a plaintext pass-through.
class ScrcSocketClient {
  ScrcSocketClient({
    this.host = '127.0.0.1',
    this.port = 27183,
    this.cipher,
    this.connectTimeout = const Duration(seconds: 2),
  });

  final String host;
  final int port;
  final PskCipher? cipher;
  final Duration connectTimeout;

  String get endpoint {
    final target = host.trim();
    final displayHost = target.contains(':') ? '[$target]' : target;
    return '$displayHost:$port';
  }

  Future<ScrcConnection> connect() async {
    final target = host.trim();
    if (target.isEmpty) {
      throw const ScrcConnectionException(
        'SCRC host is empty; enter the phone LAN IP in wireless mode.',
      );
    }
    try {
      final socket = await Socket.connect(
        target,
        port,
        timeout: connectTimeout,
      );
      // TCP_NODELAY (and its connect log line) is applied by TcpTransport.
      final transport = TcpTransport(socket);
      return ScrcConnection._(
        SecureChannel(transport, cipher),
        remoteAddress: transport.remoteAddress,
      );
    } on SocketException catch (error) {
      throw ScrcConnectionException(
        'Could not connect to SCRC at $endpoint: ${error.message}',
      );
    } on TimeoutException {
      throw ScrcConnectionException(
        'Timed out connecting to SCRC at $endpoint.',
      );
    }
  }

  Future<ScrcConnection> connectWithRetry({
    Duration timeout = const Duration(seconds: 8),
    Duration interval = const Duration(milliseconds: 250),
  }) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;

    while (DateTime.now().isBefore(deadline)) {
      try {
        return await connect();
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(interval);
      }
    }

    throw ScrcConnectionException(
      'Could not connect to $endpoint within ${timeout.inSeconds}s. '
      '${lastError ?? ''}',
    );
  }
}

/// A live SCRC connection. One connection carries one capture session.
class ScrcConnection {
  ScrcConnection._(this._channel, {required this.remoteAddress}) {
    _subscription = _channel.incoming.listen(
      _handleData,
      onError: _handleError,
      onDone: _handleDone,
      cancelOnError: false,
    );
  }

  final Transport _channel;
  final String remoteAddress;
  final ScrcPacketDecoder _decoder = ScrcPacketDecoder();
  final StreamController<ScrcPacket> _packets = StreamController<ScrcPacket>();

  StreamSubscription<Uint8List>? _subscription;
  bool _closed = false;

  Stream<ScrcPacket> get packets => _packets.stream;

  void _handleData(Uint8List data) {
    try {
      for (final packet in _decoder.add(data)) {
        if (!_packets.isClosed) {
          _packets.add(packet);
        }
      }
    } catch (error, stackTrace) {
      if (!_packets.isClosed) {
        _packets.addError(error, stackTrace);
      }
      unawaited(close());
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    if (!_packets.isClosed) {
      _packets.addError(error, stackTrace);
    }
  }

  void _handleDone() {
    if (!_packets.isClosed) {
      _packets.close();
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _channel.close();
    } catch (_) {
      // The remote side may already have closed.
    }
    if (!_packets.isClosed) {
      await _packets.close();
    }
  }
}

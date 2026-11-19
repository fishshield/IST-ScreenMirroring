import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Whether [TcpTransport] enables TCP_NODELAY on the sockets it wraps.
///
/// Enabled by default. The switch exists for the latency A/B measurement:
/// `--dart-define=SCREEN_CAST_TCP_NODELAY=false` runs the same session with
/// Nagle's algorithm left on.
const bool tcpNoDelayEnabled = bool.fromEnvironment(
  'SCREEN_CAST_TCP_NODELAY',
  defaultValue: true,
);

/// Byte-oriented transport underneath the record layer.
///
/// Everything above this interface — [SecureChannel], the SCRC packet decoder
/// and the control-frame codec — deals only in opaque byte chunks. That is what
/// keeps encryption independent from either protocol.
abstract class Transport {
  /// Raw inbound bytes, in arrival order. Single-subscription.
  Stream<Uint8List> get incoming;

  /// Queues [bytes] for transmission. Never throws for an already-closed link.
  void send(Uint8List bytes);

  Future<void> close();
}

/// [Transport] over a connected [Socket].
///
/// The socket is created by the caller (the existing connect/retry logic stays
/// untouched); this class adapts the stream and write calls and owns the
/// TCP_NODELAY setting, so both the SCRC (27183) and control (27184) sockets are
/// configured and logged the same way.
class TcpTransport implements Transport {
  TcpTransport(this._socket, {String? remoteAddress})
      : remoteAddress = remoteAddress ??
            '${_socket.remoteAddress.address}:${_socket.remotePort}' {
    noDelay = _applyNoDelay(_socket, this.remoteAddress);
    _subscription = _socket.listen(
      (Uint8List chunk) {
        if (!_incoming.isClosed) {
          _incoming.add(chunk);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_incoming.isClosed) {
          _incoming.addError(error, stackTrace);
        }
      },
      onDone: () {
        if (!_incoming.isClosed) {
          _incoming.close();
        }
      },
      cancelOnError: false,
    );
  }

  /// Connects and wraps the socket. Kept as a convenience for callers that do
  /// not need custom retry logic.
  static Future<TcpTransport> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    return TcpTransport(socket);
  }

  /// Applies TCP_NODELAY and reports the resulting state in the connect log.
  ///
  /// Nagle's algorithm delays small writes (control frames are 5-9 bytes) by up
  /// to the peer ACK, which adds tens of milliseconds on a LAN round trip.
  static bool _applyNoDelay(Socket socket, String label) {
    if (!tcpNoDelayEnabled) {
      debugPrint(
        '[tcp] $label TCP_NODELAY=false '
        '(disabled by --dart-define=SCREEN_CAST_TCP_NODELAY=false)',
      );
      return false;
    }
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (error) {
      debugPrint('[tcp] $label TCP_NODELAY=true failed: $error');
      return false;
    }
    debugPrint('[tcp] $label TCP_NODELAY=true');
    return true;
  }

  final Socket _socket;
  final String remoteAddress;

  /// Result of applying TCP_NODELAY to this socket (false when disabled or the
  /// platform rejected the option).
  late final bool noDelay;

  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>();
  StreamSubscription<Uint8List>? _subscription;
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  void send(Uint8List bytes) {
    if (_closed || bytes.isEmpty) {
      return;
    }
    try {
      _socket.add(bytes);
    } catch (_) {
      // The peer is gone; the incoming stream reports the failure.
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _socket.close();
    } catch (_) {
      // Already closed by the remote side.
    }
    _socket.destroy();
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }
}

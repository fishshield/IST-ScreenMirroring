import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/psk_cipher.dart';
import '../transport/secure_channel.dart';
import '../transport/transport.dart';
import 'control_message.dart';

/// Client for the control channel (default port 27184).
///
/// Deliberately independent from the SCRC video socket: a control failure must
/// never tear down the video session. [connect] is best-effort, [send] silently
/// drops frames once the link is gone, and [onDisconnected] fires at most once
/// per connection so the UI can show "控制已断开" while frames keep flowing.
///
/// Bytes go through a [SecureChannel]; the control frame layout is untouched.
/// A null [cipher] means a plaintext pass-through.
class ControlClient {
  ControlClient({
    required this.host,
    required this.port,
    this.cipher,
    this.connectTimeout = const Duration(seconds: 3),
  });

  final String host;
  final int port;
  final PskCipher? cipher;
  final Duration connectTimeout;

  Transport? _channel;
  StreamSubscription<Uint8List>? _subscription;
  bool _closed = false;

  /// Fired when the peer closes the socket or a write fails.
  void Function()? onDisconnected;

  bool get isConnected => _channel != null;

  String get endpoint {
    final hostText = host.contains(':') ? '[$host]' : host;
    return '$hostText:$port';
  }

  /// Connects and starts draining the (currently unused) inbound direction.
  /// Throws when the control port is unreachable; callers treat that as a
  /// degraded session, not a failed cast.
  Future<void> connect() async {
    final socket = await Socket.connect(host, port, timeout: connectTimeout)
        .timeout(connectTimeout);
    // TCP_NODELAY is applied (and logged) by TcpTransport for this socket too.
    final channel = SecureChannel(TcpTransport(socket), cipher);
    _channel = channel;
    _closed = false;
    _subscription = channel.incoming.listen(
      (_) {},
      onDone: _handleClosed,
      onError: (Object _) => _handleClosed(),
      cancelOnError: false,
    );
  }

  /// Returns false when the frame could not be written (link already gone).
  bool send(ControlMessage message) {
    final channel = _channel;
    if (channel == null) {
      return false;
    }
    try {
      channel.send(message.encode());
      return true;
    } catch (_) {
      _handleClosed();
      return false;
    }
  }

  Future<void> close() async {
    _closed = true;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final channel = _channel;
    _channel = null;
    try {
      await channel?.close();
    } catch (_) {
      // The peer is already gone; nothing else to release.
    }
  }

  void _handleClosed() {
    if (_closed || _channel == null) {
      return;
    }
    _channel = null;
    _closed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    onDisconnected?.call();
  }
}

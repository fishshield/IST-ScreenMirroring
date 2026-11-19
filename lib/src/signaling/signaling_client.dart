import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'signaling_message.dart';

abstract interface class SignalingClient {
  Stream<SignalingMessage> get messages;

  Future<void> connect(Uri endpoint);

  Future<void> send(SignalingMessage message);

  Future<void> close();
}

/// WebSocket signaling adapter skeleton.
///
/// This is deliberately thin: no reconnect policy, authentication, or offer /
/// answer negotiation yet. `messages` may emit errors from the socket.
class WebSocketSignalingClient implements SignalingClient {
  final StreamController<SignalingMessage> _messages =
      StreamController<SignalingMessage>.broadcast(sync: true);

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _closed = false;

  @override
  Stream<SignalingMessage> get messages => _messages.stream;

  @override
  Future<void> connect(Uri endpoint) async {
    if (_closed) {
      throw StateError('Signaling client has already been closed.');
    }
    if (_channel != null) {
      throw StateError('Signaling client is already connected.');
    }

    final channel = WebSocketChannel.connect(endpoint);
    await channel.ready;
    _channel = channel;
    _subscription = channel.stream.listen(
      (dynamic event) {
        final message = SignalingMessage.tryParse(event);
        if (message == null) {
          _messages.addError(
            const FormatException('Invalid signaling message envelope.'),
          );
          return;
        }
        _messages.add(message);
      },
      onError: _messages.addError,
      onDone: () {
        _channel = null;
      },
    );
  }

  @override
  Future<void> send(SignalingMessage message) async {
    final channel = _channel;
    if (channel == null) {
      throw StateError('Signaling client is not connected.');
    }
    channel.sink.add(message.encode());
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    await _messages.close();
  }
}

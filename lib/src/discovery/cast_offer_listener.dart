import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'cast_offer.dart';
import 'local_subnet.dart';
import 'windows_ip_table.dart';

/// One validated discovery announcement plus the address it arrived from.
@immutable
class CastOfferEvent {
  const CastOfferEvent({required this.offer, required this.source});

  final CastOffer offer;

  /// Sender address of the UDP datagram. Always equal to `offer.ip`: packets
  /// whose payload names a different host are dropped.
  final InternetAddress source;

  @override
  String toString() => 'CastOfferEvent($offer from ${source.address})';
}

/// Listens on UDP/27185 for phone announcements.
///
/// The socket binds `0.0.0.0` so a multi-homed desktop receives broadcasts on
/// every adapter. A datagram is only forwarded when **both** checks pass:
///
/// 1. the sender address is on one of this host's IPv4 subnets, and
/// 2. the payload's `ip` matches the sender address.
///
/// Together they stop a relayed or spoofed offer from pointing the desktop at a
/// device on another network. Nothing else is trusted from the packet: the PSK
/// never appears in it and the actual session still runs over TCP with the
/// existing record layer.
class CastOfferListener {
  CastOfferListener({
    this.port = CastOffer.discoveryPort,
    Future<LocalSubnetTable> Function()? subnetLoader,
  }) : _subnetLoader = subnetLoader ?? _loadDefaultSubnets;

  static Future<LocalSubnetTable> _loadDefaultSubnets() {
    return loadLocalSubnetTable(
      maskLoader: Platform.isWindows ? loadWindowsPrefixLengths : null,
    );
  }

  final int port;
  final Future<LocalSubnetTable> Function() _subnetLoader;

  final StreamController<CastOfferEvent> _events =
      StreamController<CastOfferEvent>.broadcast();

  RawDatagramSocket? _socket;
  LocalSubnetTable _subnets = const LocalSubnetTable(<LocalSubnet>[]);
  bool _started = false;

  int _droppedOffSubnet = 0;
  int _droppedAddressMismatch = 0;
  int _droppedMalformed = 0;
  int _accepted = 0;

  /// Validated offers; broadcast so multiple listeners can subscribe.
  Stream<CastOfferEvent> get offers => _events.stream;

  bool get isListening => _socket != null;

  LocalSubnetTable get subnets => _subnets;

  int get acceptedCount => _accepted;
  int get droppedOffSubnet => _droppedOffSubnet;
  int get droppedAddressMismatch => _droppedAddressMismatch;
  int get droppedMalformed => _droppedMalformed;

  /// Binds the discovery socket. Returns false (and logs) when the port cannot
  /// be bound; the rest of the app keeps working.
  Future<bool> start() async {
    if (_started) {
      return true;
    }
    _subnets = await _subnetLoader();
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      socket.listen(
        _handleSocketEvent,
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('[discovery] socket error: $error');
        },
      );
      _socket = socket;
      _started = true;
      debugPrint(
        '[discovery] listening on udp/0.0.0.0:$port '
        '(${_subnets.subnets.length} local IPv4 subnets: '
        '${_subnets.subnets.map((LocalSubnet s) => s.cidr).join(', ')})',
      );
      return true;
    } catch (error) {
      debugPrint(
        '[discovery] cannot bind udp/$port: $error; '
        'auto-connect stays unavailable',
      );
      return false;
    }
  }

  Future<void> stop() async {
    final socket = _socket;
    _socket = null;
    _started = false;
    socket?.close();
    if (socket != null) {
      debugPrint('[discovery] listener stopped');
    }
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  /// Replaces the subnet table (tests, or after a network change).
  @visibleForTesting
  void overrideSubnets(LocalSubnetTable table) {
    _subnets = table;
  }

  /// Applies the trust checks and forwards a well-formed offer.
  ///
  /// Exposed for tests so the policy can be exercised without real sockets.
  @visibleForTesting
  void ingest(InternetAddress source, List<int> data) {
    final text = utf8.decode(data, allowMalformed: true);
    final offer = CastOffer.tryParse(text);
    if (offer == null) {
      _droppedMalformed++;
      final preview =
          text.length > 120 ? '${text.substring(0, 120)}…' : text.trim();
      debugPrint(
        '[discovery] ignored malformed datagram from ${source.address}: '
        '"$preview"',
      );
      return;
    }
    if (!_subnets.accepts(source)) {
      _droppedOffSubnet++;
      debugPrint(
        '[discovery] ignored offer ${offer.ip}: sender ${source.address} '
        'is not on a local subnet',
      );
      return;
    }
    if (offer.ip != source.address) {
      _droppedAddressMismatch++;
      debugPrint(
        '[discovery] ignored offer: payload ip ${offer.ip} does not match '
        'sender ${source.address}',
      );
      return;
    }
    _accepted++;
    debugPrint(
      '[discovery] offer from ${offer.ip} video=${offer.videoPort} '
      'control=${offer.controlPort} pskRequired=${offer.pskRequired}',
    );
    if (!_events.isClosed) {
      _events.add(CastOfferEvent(offer: offer, source: source));
    }
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    final socket = _socket;
    if (socket == null) {
      return;
    }
    // Drain everything that is queued: one broadcast burst can coalesce into
    // several datagrams and the loop keeps the backlog empty.
    while (true) {
      final datagram = socket.receive();
      if (datagram == null) {
        break;
      }
      ingest(datagram.address, datagram.data);
    }
  }
}

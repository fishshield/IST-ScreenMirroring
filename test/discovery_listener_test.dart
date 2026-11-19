import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/discovery/cast_offer.dart';
import 'package:screen_cast_demo/src/discovery/cast_offer_listener.dart';
import 'package:screen_cast_demo/src/discovery/local_subnet.dart';

CastOfferListener buildListener() {
  final table = LocalSubnetTable(<LocalSubnet>[
    LocalSubnet(
      address: InternetAddress('192.168.1.203'),
      prefixLength: 24,
    ),
  ]);
  final listener = CastOfferListener(
    subnetLoader: () async => table,
  )..overrideSubnets(table);
  return listener;
}

void main() {
  test('forwards an offer whose sender is on a local subnet', () async {
    final listener = buildListener();
    final events = <CastOfferEvent>[];
    final subscription = listener.offers.listen(events.add);
    addTearDown(() async {
      await subscription.cancel();
      await listener.dispose();
    });

    listener.ingest(
      InternetAddress('192.168.1.134'),
      utf8.encode(
        const CastOffer(ip: '192.168.1.134').encode(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect(events.single.offer.ip, '192.168.1.134');
    expect(events.single.source.address, '192.168.1.134');
    expect(listener.acceptedCount, 1);
  });

  test('drops an offer from another subnet (multi-NIC safety)', () async {
    final listener = buildListener();
    final events = <CastOfferEvent>[];
    final subscription = listener.offers.listen(events.add);
    addTearDown(() async {
      await subscription.cancel();
      await listener.dispose();
    });

    listener.ingest(
      InternetAddress('192.168.32.10'),
      utf8.encode(const CastOffer(ip: '192.168.32.10').encode()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
    expect(listener.droppedOffSubnet, 1);
    expect(listener.acceptedCount, 0);
  });

  test('drops a packet whose payload names a different host', () async {
    final listener = buildListener();
    final events = <CastOfferEvent>[];
    final subscription = listener.offers.listen(events.add);
    addTearDown(() async {
      await subscription.cancel();
      await listener.dispose();
    });

    // Sender is local, but it tries to point the desktop at another device.
    listener.ingest(
      InternetAddress('192.168.1.134'),
      utf8.encode(const CastOffer(ip: '192.168.1.10').encode()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
    expect(listener.droppedAddressMismatch, 1);
  });

  test('drops malformed datagrams', () async {
    final listener = buildListener();
    final events = <CastOfferEvent>[];
    final subscription = listener.offers.listen(events.add);
    addTearDown(() async {
      await subscription.cancel();
      await listener.dispose();
    });

    listener.ingest(InternetAddress('192.168.1.134'), utf8.encode('hello'));
    listener.ingest(
      InternetAddress('192.168.1.134'),
      utf8.encode('{"type":"other"}'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
    expect(listener.droppedMalformed, 2);
  });

  test('loopback senders are rejected even when they are on a local subnet',
      () async {
    final listener = CastOfferListener(
      subnetLoader: () async => const LocalSubnetTable(<LocalSubnet>[]),
    )..overrideSubnets(
        LocalSubnetTable(<LocalSubnet>[
          LocalSubnet(
            address: InternetAddress('127.0.0.1'),
            prefixLength: 8,
          ),
        ]),
      );
    final events = <CastOfferEvent>[];
    final subscription = listener.offers.listen(events.add);
    addTearDown(() async {
      await subscription.cancel();
      await listener.dispose();
    });

    listener.ingest(
      InternetAddress('127.0.0.1'),
      utf8.encode(const CastOffer(ip: '127.0.0.1').encode()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
    expect(listener.droppedOffSubnet, 1);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/discovery/local_subnet.dart';

InternetAddress ip(String text) => InternetAddress(text);

void main() {
  group('prefixFromMask', () {
    test('maps contiguous masks to prefix lengths', () {
      expect(prefixFromMask(0x00000000), 0);
      expect(prefixFromMask(0x80000000), 1);
      expect(prefixFromMask(0xFFFFFF00), 24);
      expect(prefixFromMask(0xFFFFF000), 20);
      expect(prefixFromMask(0xFFFF0000), 16);
      expect(prefixFromMask(0xFFFFFFFF), 32);
    });

    test('rejects non-contiguous masks', () {
      expect(prefixFromMask(0xFFFFFF0F), isNull);
      expect(prefixFromMask(0x00FF00FF), isNull);
    });
  });

  group('LocalSubnet', () {
    test('contains addresses of the same network only', () {
      final subnet =
          LocalSubnet(address: ip('192.168.1.203'), prefixLength: 24);
      expect(subnet.contains(ip('192.168.1.134')), isTrue);
      expect(subnet.contains(ip('192.168.1.255')), isTrue);
      expect(subnet.contains(ip('192.168.32.1')), isFalse);
      expect(subnet.contains(ip('10.0.0.1')), isFalse);
      expect(subnet.contains(ip('::1')), isFalse);
    });

    test('honours non-/24 prefixes', () {
      final subnet = LocalSubnet(address: ip('10.1.2.3'), prefixLength: 16);
      expect(subnet.contains(ip('10.1.9.9')), isTrue);
      expect(subnet.contains(ip('10.2.0.1')), isFalse);
      expect(subnet.cidr, '10.1.2.3/16');
    });
  });

  group('LocalSubnetTable', () {
    final table = LocalSubnetTable(<LocalSubnet>[
      LocalSubnet(address: ip('192.168.1.203'), prefixLength: 24),
      LocalSubnet(address: ip('10.20.30.40'), prefixLength: 16),
    ]);

    test('accepts senders on any local subnet', () {
      expect(table.accepts(ip('192.168.1.134')), isTrue);
      expect(table.accepts(ip('10.20.99.1')), isTrue);
    });

    test('rejects other subnets, loopback and link-local', () {
      expect(table.accepts(ip('192.168.32.10')), isFalse);
      expect(table.accepts(ip('172.16.0.9')), isFalse);
      expect(table.accepts(ip('127.0.0.1')), isFalse);
      expect(table.accepts(ip('169.254.10.20')), isFalse);
      expect(table.accepts(ip('fe80::1')), isFalse);
    });

    test('empty table accepts nothing', () {
      const empty = LocalSubnetTable(<LocalSubnet>[]);
      expect(empty.isEmpty, isTrue);
      expect(empty.accepts(ip('192.168.1.134')), isFalse);
    });

    test('builds from address/mask pairs and skips bad masks', () {
      final built = LocalSubnetTable.fromAddressMasks(<({int address, int mask})>[
        // 192.168.1.203/24
        (address: 0xC0A801CB, mask: 0xFFFFFF00),
        // 172.16.5.6/20
        (address: 0xAC100506, mask: 0xFFFFF000),
        // Non-contiguous mask: must be skipped, never widened.
        (address: 0x0A000001, mask: 0xFFFFFF0F),
      ]);
      expect(built.subnets, hasLength(2));
      expect(built.accepts(ip('192.168.1.9')), isTrue);
      expect(built.accepts(ip('172.16.2.2')), isTrue);
      expect(built.accepts(ip('10.0.0.1')), isFalse);
    });
  });

  test('internetAddressFromInt uses big-endian octets', () {
    expect(internetAddressFromInt(0xC0A80101)?.address, '192.168.1.1');
    expect(internetAddressFromInt(0x0A000001)?.address, '10.0.0.1');
  });
}

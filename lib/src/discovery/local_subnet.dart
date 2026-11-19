import 'dart:io';

import 'package:flutter/foundation.dart';

/// One IPv4 subnet of a local network interface: address + prefix length.
@immutable
class LocalSubnet {
  const LocalSubnet({required this.address, required this.prefixLength})
      : assert(prefixLength >= 0 && prefixLength <= 32);

  final InternetAddress address;
  final int prefixLength;

  int get _mask {
    if (prefixLength == 0) {
      return 0;
    }
    return (0xFFFFFFFF << (32 - prefixLength)) & 0xFFFFFFFF;
  }

  /// Whether [other] falls inside this subnet.
  ///
  /// IPv6 addresses never match: discovery is IPv4-only (the Android
  /// broadcaster only emits IPv4 interface addresses).
  bool contains(InternetAddress other) {
    final local = address.rawAddress;
    final remote = other.rawAddress;
    if (local.length != 4 || remote.length != 4) {
      return false;
    }
    final mask = _mask;
    return (_toInt(remote) & mask) == (_toInt(local) & mask);
  }

  /// Dotted prefix, e.g. `192.168.1.0/24`.
  String get cidr => '${address.address}/$prefixLength';

  @override
  String toString() => 'LocalSubnet($cidr)';

  @override
  bool operator ==(Object other) =>
      other is LocalSubnet &&
      other.address == address &&
      other.prefixLength == prefixLength;

  @override
  int get hashCode => Object.hash(address, prefixLength);
}

/// Every IPv4 subnet this host can be reached on.
///
/// Used to reject discovery datagrams that arrive from another subnet (or a
/// spoofed/relayed address) before any TCP connection is attempted. The
/// sender is also compared with the address it advertises, so a packet cannot
/// point the desktop at a third device.
@immutable
class LocalSubnetTable {
  const LocalSubnetTable(this.subnets);

  /// Fallback used when the interface mask cannot be read; the desktop only
  /// refuses addresses, it never accepts a wider range than it can prove.
  static const int fallbackPrefixLength = 24;

  final List<LocalSubnet> subnets;

  bool get isEmpty => subnets.isEmpty;

  /// Whether [source] is on one of the subnets on this host.
  ///
  /// Loopback, link-local (169.254/16) and non-IPv4 addresses are rejected:
  /// the phone broadcasts on its LAN interfaces, never through loopback.
  bool accepts(InternetAddress source) {
    final raw = source.rawAddress;
    if (raw.length != 4) {
      return false;
    }
    if (raw[0] == 127) {
      return false;
    }
    if (raw[0] == 169 && raw[1] == 254) {
      return false;
    }
    for (final subnet in subnets) {
      if (subnet.contains(source)) {
        return true;
      }
    }
    return false;
  }

  /// Builds a table from `(address, mask)` pairs, e.g. the Windows IP table.
  ///
  /// Entries whose mask is non-contiguous are skipped: a mask that is not a
  /// run of leading ones cannot describe a subnet safely.
  factory LocalSubnetTable.fromAddressMasks(
    Iterable<({int address, int mask})> entries,
  ) {
    final subnets = <LocalSubnet>[];
    for (final entry in entries) {
      final prefix = prefixFromMask(entry.mask);
      if (prefix == null) {
        continue;
      }
      final address = internetAddressFromInt(entry.address);
      if (address == null) {
        continue;
      }
      subnets.add(LocalSubnet(address: address, prefixLength: prefix));
    }
    return LocalSubnetTable(subnets);
  }

  @override
  String toString() =>
      'LocalSubnetTable([${subnets.map((s) => s.cidr).join(', ')}])';
}

/// Number of leading one bits in [mask], or null when [mask] is not a
/// contiguous netmask.
int? prefixFromMask(int mask) {
  final normalized = mask & 0xFFFFFFFF;
  if (normalized == 0) {
    return 0;
  }
  final inverted = (~normalized) & 0xFFFFFFFF;
  if ((inverted & (inverted + 1)) != 0) {
    return null;
  }
  return 32 - inverted.bitLength;
}

/// Converts a host-order 32-bit IPv4 value to an [InternetAddress].
InternetAddress? internetAddressFromInt(int value) {
  final normalized = value & 0xFFFFFFFF;
  final bytes = Uint8List(4)
    ..[0] = (normalized >> 24) & 0xFF
    ..[1] = (normalized >> 16) & 0xFF
    ..[2] = (normalized >> 8) & 0xFF
    ..[3] = normalized & 0xFF;
  try {
    return InternetAddress.fromRawAddress(bytes);
  } on ArgumentError {
    return null;
  }
}

int _toInt(List<int> bytes) =>
    ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
    0xFFFFFFFF;

/// Loads every non-loopback IPv4 subnet of this host.
///
/// Addresses come from [NetworkInterface.list]; the prefix length comes from
/// the platform (Windows IP table, see `windows_ip_table.dart`). When masks are
/// unavailable (non-Windows host, FFI failure) a /24 is assumed, which can only
/// make the check stricter, never laxer.
Future<LocalSubnetTable> loadLocalSubnetTable({
  Future<Map<String, int>> Function()? maskLoader,
}) async {
  final Map<String, int> prefixes;
  try {
    prefixes = maskLoader == null
        ? const <String, int>{}
        : await maskLoader();
  } catch (error) {
    // Keep the /24 fallback: a missing mask must not disable discovery.
    debugPrint('[discovery] interface mask lookup failed: $error');
    return _subnetsFromInterfaces(const <String, int>{});
  }

  return _subnetsFromInterfaces(prefixes);
}

Future<LocalSubnetTable> _subnetsFromInterfaces(
  Map<String, int> prefixes,
) async {
  final subnets = <LocalSubnet>[];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.rawAddress.length != 4) {
          continue;
        }
        final prefix =
            prefixes[address.address] ?? LocalSubnetTable.fallbackPrefixLength;
        subnets.add(LocalSubnet(address: address, prefixLength: prefix));
      }
    }
  } catch (error) {
    debugPrint('[discovery] interface enumeration failed: $error');
    return LocalSubnetTable(const []);
  }
  return LocalSubnetTable(subnets);
}

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'local_subnet.dart';

/// Reads the Windows IPv4 interface table (address + netmask per adapter).
///
/// `NetworkInterface.list` only exposes addresses, but the discovery filter
/// needs the prefix length to decide whether a broadcast came from the same
/// subnet. `GetIpAddrTable` (iphlpapi) returns both; the struct layout is fixed
/// since Windows 2000 and is validated by the unit tests through
/// [LocalSubnetTable.fromAddressMasks].
const int _errorInsufficientBuffer = 122;

/// Returns the prefix length per local IPv4 address, e.g.
/// `{'192.168.1.203': 24}`. Empty when the platform call fails; callers then
/// fall back to a /24 assumption.
Future<Map<String, int>> loadWindowsPrefixLengths() async {
  final prefixes = <String, int>{};
  for (final entry in readWindowsIpTable()) {
    final prefix = prefixFromMask(entry.mask);
    final address = internetAddressFromInt(entry.address);
    if (prefix == null || prefix == 0 || address == null) {
      continue;
    }
    if (address.rawAddress[0] == 127) {
      continue;
    }
    prefixes[address.address] = prefix;
  }
  return prefixes;
}

typedef _GetIpAddrTableNative = Uint32 Function(
  Pointer<Uint8>,
  Pointer<Uint32>,
  Int32,
);
typedef _GetIpAddrTableDart = int Function(
  Pointer<Uint8>,
  Pointer<Uint32>,
  int,
);

/// MIB_IPADDRROW (winsock2.h): 24 bytes, `dwAddr`/`dwMask` in network order.
final class _MibIpAddrRow extends Struct {
  @Uint32()
  external int address;

  @Uint32()
  external int index;

  @Uint32()
  external int mask;

  @Uint32()
  external int broadcast;

  @Uint32()
  external int reassemblySize;

  @Uint16()
  external int unused;

  @Uint16()
  external int type;
}

/// Raw `(address, mask)` pairs in host byte order.
///
/// Empty on any failure, including non-Windows hosts: discovery then keeps the
/// conservative /24 fallback instead of failing open.
@visibleForTesting
List<({int address, int mask})> readWindowsIpTable() {
  if (!Platform.isWindows) {
    return const [];
  }
  final _GetIpAddrTableDart getIpAddrTable;
  try {
    final library = DynamicLibrary.open('iphlpapi.dll');
    getIpAddrTable = library.lookupFunction<
        _GetIpAddrTableNative, _GetIpAddrTableDart>('GetIpAddrTable');
  } catch (error) {
    debugPrint('[discovery] iphlpapi unavailable: $error');
    return const [];
  }

  final size = calloc<Uint32>();
  Pointer<Uint8> buffer = nullptr;
  try {
    var status = getIpAddrTable(nullptr, size, 0);
    if (status != _errorInsufficientBuffer && status != 0) {
      debugPrint('[discovery] GetIpAddrTable size probe failed: $status');
      return const [];
    }
    final bytes = size.value;
    if (bytes < 4) {
      return const [];
    }
    buffer = calloc<Uint8>(bytes);
    status = getIpAddrTable(buffer, size, 0);
    if (status != 0) {
      debugPrint('[discovery] GetIpAddrTable failed: $status');
      return const [];
    }

    final count = buffer.cast<Uint32>().value;
    final rows = Pointer<_MibIpAddrRow>.fromAddress(buffer.address + 4);
    final entries = <({int address, int mask})>[];
    for (var index = 0; index < count; index++) {
      final row = rows[index];
      entries.add((
        address: _ntohl(row.address),
        mask: _ntohl(row.mask),
      ));
    }
    return entries;
  } catch (error) {
    debugPrint('[discovery] IP table read failed: $error');
    return const [];
  } finally {
    calloc.free(size);
    if (buffer != nullptr) {
      calloc.free(buffer);
    }
  }
}

/// Network-order DWORD (as read into a little-endian int) to host order.
int _ntohl(int value) {
  final v = value & 0xFFFFFFFF;
  return (((v & 0xFF) << 24) |
          ((v & 0xFF00) << 8) |
          ((v >> 8) & 0xFF00) |
          ((v >> 24) & 0xFF)) &
      0xFFFFFFFF;
}

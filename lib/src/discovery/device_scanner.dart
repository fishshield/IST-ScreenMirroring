import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../host/adb_launcher.dart';

/// How a discovered device can be reached.
enum DiscoveredDeviceKind {
  /// USB (or already connected ADB) device; the desktop pushes and starts the
  /// server over ADB.
  usb,

  /// Phone on the LAN that already listens on 27184; the desktop only connects.
  lan,
}

/// One entry in the "扫描设备" list.
@immutable
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.kind,
    required this.id,
    required this.label,
    required this.detail,
    this.serial,
    this.host,
  });

  final DiscoveredDeviceKind kind;

  /// Stable identity for selection (`serial` for USB, IP for LAN).
  final String id;
  final String label;
  final String detail;

  /// ADB serial (USB entries only).
  final String? serial;

  /// Phone LAN address (LAN entries only).
  final String? host;

  @override
  bool operator ==(Object other) =>
      other is DiscoveredDevice && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'DiscoveredDevice(${kind.name}, $id)';
}

/// Finds connectable phones for the merged device list.
///
/// * **USB**: `adb devices` (authorized devices only).
/// * **LAN**: a short TCP sweep of each local /24 on the **control** port
///   (27184), never the video port. The video listener treats any connection as
///   a new viewer: probing 27183 used to restart the whole capture (new virtual
///   display, IDR, MediaCodec) every scan, which showed up as periodic
///   stutter while casting. The control listener just accepts and sees EOF.
///   The UDP discovery offers are still the fast path once a phone announces
///   itself.
class DeviceScanner {
  DeviceScanner({
    Future<List<String>> Function()? adbSerials,
    Future<List<String>> Function()? lanHosts,
    this.lanPort = 27184,
  })  : _adbSerials = adbSerials ?? _defaultAdbSerials,
        _lanHosts = lanHosts ?? _defaultLanHosts;

  final Future<List<String>> Function() _adbSerials;
  final Future<List<String>> Function() _lanHosts;
  final int lanPort;

  /// USB first, then LAN, both sorted for a stable list.
  Future<List<DiscoveredDevice>> scan() async {
    final devices = <DiscoveredDevice>[];
    // Phones already visible through ADB (e.g. `ip:5555`) are also reachable by
    // the port sweep; keep one row per phone instead of two.
    final adbHosts = <String>{};
    try {
      final serials = await _adbSerials();
      final sorted = serials.toSet().toList()..sort();
      for (final serial in sorted) {
        // `adb devices` also lists devices already connected over TCP
        // (host:5555). Those are wireless: show the LAN icon and connect in
        // wireless mode (the desktop still starts the server over ADB/TCP).
        if (serial.contains(':')) {
          final host = serial.substring(0, serial.lastIndexOf(':'));
          adbHosts.add(host);
          devices.add(
            DiscoveredDevice(
              kind: DiscoveredDeviceKind.lan,
              id: serial,
              label: host,
              detail: '无线 ADB · $serial',
              host: host,
              serial: serial,
            ),
          );
          continue;
        }
        devices.add(
          DiscoveredDevice(
            kind: DiscoveredDeviceKind.usb,
            id: serial,
            label: serial,
            detail: 'USB · ADB 已授权',
            serial: serial,
          ),
        );
      }
    } catch (error) {
      debugPrint('[scan] adb devices failed: $error');
    }
    try {
      final hosts = (await _lanHosts())
          .where((String host) => !adbHosts.contains(host))
          .toList();
      final sorted = hosts.toSet().toList()..sort();
      for (final host in sorted) {
        devices.add(
          DiscoveredDevice(
            kind: DiscoveredDeviceKind.lan,
            id: host,
            label: host,
            detail: '局域网 · 端口 $lanPort 可连接',
            host: host,
          ),
        );
      }
    } catch (error) {
      debugPrint('[scan] LAN sweep failed: $error');
    }
    return devices;
  }

  static Future<List<String>> _defaultAdbSerials() async {
    final launcher = AdbLauncher();
    final adb = await launcher.resolveAdbPath();
    final result = await Process.run(adb, <String>['devices']);
    if (result.exitCode != 0) {
      return const [];
    }
    return AdbLauncher.parseDeviceSerials(result.stdout.toString());
  }

  static Future<List<String>> _defaultLanHosts() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final targets = <String>{};
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final raw = address.rawAddress;
        if (raw.length != 4) {
          continue;
        }
        // Sweep the /24 around each local address; a wider sweep would take
        // minutes and is not useful for a desktop casting tool.
        final prefix = '${raw[0]}.${raw[1]}.${raw[2]}';
        for (var host = 1; host <= 254; host++) {
          final candidate = '$prefix.$host';
          if (candidate != address.address) {
            targets.add(candidate);
          }
        }
      }
    }
    return probeHosts(targets, port: 27184);
  }

  /// Concurrently checks [hosts] for an open [port]; returns reachable ones.
  @visibleForTesting
  static Future<List<String>> probeHosts(
    Iterable<String> hosts, {
    int port = 27184,
    Duration timeout = const Duration(milliseconds: 200),
    int concurrency = 32,
  }) async {
    final queue = hosts.toList();
    final reachable = <String>[];
    var index = 0;
    Future<void> worker() async {
      while (true) {
        final current = index++;
        if (current >= queue.length) {
          return;
        }
        final host = queue[current];
        Socket? socket;
        try {
          socket = await Socket.connect(host, port, timeout: timeout);
          reachable.add(host);
        } catch (_) {
          // Closed port / unreachable host: not a casting device.
        } finally {
          socket?.destroy();
        }
      }
    }

    await Future.wait(
      List<Future<void>>.generate(concurrency, (_) => worker()),
    );
    return reachable;
  }
}

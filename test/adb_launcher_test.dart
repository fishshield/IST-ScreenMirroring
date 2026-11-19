import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/host/adb_forward.dart';
import 'package:screen_cast_demo/src/host/adb_launcher.dart';
import 'package:screen_cast_demo/src/transport/cast_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses only authorized adb devices', () {
    const output = '''
List of devices attached
emulator-5554\tdevice
R58M123ABC\tdevice
unauthorized-device\tunauthorized
offline-device\toffline

''';

    expect(
      AdbLauncher.parseDeviceSerials(output),
      <String>['emulator-5554', 'R58M123ABC'],
    );
  });

  test('ships a compiled classes.dex server jar asset', () async {
    final jar = File(AdbLauncher.serverJarAssetPath);
    expect(jar.existsSync(), isTrue);
    final bytes = jar.readAsBytesSync();
    expect(bytes.length, greaterThan(1024));
    expect(bytes.sublist(0, 2), <int>[0x50, 0x4b]);

    final bundled = await rootBundle.load(AdbLauncher.serverJarAssetPath);
    expect(bundled.lengthInBytes, bytes.length);
  });

  test('resolves an installed adb executable', () async {
    final launcher = AdbLauncher();
    final path = await launcher.resolveAdbPath();
    expect(path.toLowerCase(), contains('adb'));
  });

  test('rejects an invalid port before touching adb', () async {
    final launcher = AdbLauncher(port: 80);
    await expectLater(
      launcher.start(),
      throwsA(isA<AdbException>()),
    );
  });

  test('wireless mode starts 0.0.0.0 and does not use a forward', () {
    final launcher = AdbLauncher(
      transportMode: CastTransportMode.wireless,
      targetHost: '192.168.1.23',
    );

    expect(launcher.transport.usesAdbForward, isFalse);
    expect(launcher.serverShellCommand, contains('--bind-address=0.0.0.0'));
    expect(AdbLauncher.wirelessAdbPort, 5555);
    expect(launcher.transport.endpoint, '192.168.1.23:27183');
  });

  test('wired mode uses loopback and ADB forward', () {
    final launcher = AdbLauncher();

    expect(launcher.transport.usesAdbForward, isTrue);
    expect(launcher.serverShellCommand, contains('--bind-address=127.0.0.1'));
  });

  test('passes --target-fps only when the 60 fps limit is enabled', () {
    expect(AdbLauncher().serverShellCommand, isNot(contains('--target-fps')));

    final limited = AdbLauncher(
      transportMode: CastTransportMode.wireless,
      targetHost: '192.168.1.23',
      targetFps: 60,
    );
    expect(limited.serverShellCommand, contains('--target-fps=60'));
    expect(limited.serverShellCommand, contains('--bind-address=0.0.0.0'));
  });

  test('wired mode forwards both the video and the control port', () {
    final launcher = AdbLauncher();

    final plan = launcher.forwardPlanFor('SERIAL');
    expect(plan.tunnels, <AdbForward>[
      const AdbForward.samePort(27183),
      const AdbForward.samePort(27184),
    ]);
    // CastSession connects ControlClient to the loopback forward.
    expect(launcher.transport.effectiveHost, '127.0.0.1');
    expect(launcher.transport.controlPort, 27184);
  });

  test('wireless mode does not forward the control port either', () {
    final launcher = AdbLauncher(
      transportMode: CastTransportMode.wireless,
      targetHost: '192.168.1.23',
    );

    expect(launcher.forwardPlanFor('192.168.1.23:5555').isEmpty, isTrue);
  });

  test('wireless recovery is rejected for a wired launcher', () async {
    final launcher = AdbLauncher();
    await expectLater(
      launcher.startExistingWireless('127.0.0.1:5555'),
      throwsA(isA<AdbException>()),
    );
  });
}

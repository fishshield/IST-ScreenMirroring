import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/host/adb_forward.dart';
import 'package:screen_cast_demo/src/transport/cast_transport.dart';

void main() {
  AdbForwards wiredPlan() => AdbForwards.forConfig(
        serial: 'SERIAL',
        transport: const CastTransportConfig(),
      );

  test('wired mode plans the video and control tunnels', () {
    final plan = wiredPlan();

    expect(plan.tunnels, <AdbForward>[
      const AdbForward.samePort(27183),
      const AdbForward.samePort(27184),
    ]);
    expect(plan.videoTunnel, const AdbForward.samePort(27183));
    expect(plan.controlTunnel, const AdbForward.samePort(27184));
    expect(
      plan.installArguments(plan.controlTunnel!),
      <String>['-s', 'SERIAL', 'forward', 'tcp:27184', 'tcp:27184'],
    );
    expect(
      plan.removeArguments(plan.controlTunnel!),
      <String>['-s', 'SERIAL', 'forward', '--remove', 'tcp:27184'],
    );
  });

  test('wireless and direct modes plan no tunnel', () {
    for (final mode in <CastTransportMode>[
      CastTransportMode.wireless,
      CastTransportMode.direct,
    ]) {
      final plan = AdbForwards.forConfig(
        serial: 'SERIAL',
        transport: CastTransportConfig(mode: mode, host: '192.168.1.23'),
      );
      expect(plan.isEmpty, isTrue, reason: '$mode must not forward');
      expect(plan.videoTunnel, isNull);
    }
  });

  test('install keeps going after a tunnel fails and reports it', () async {
    final plan = wiredPlan();
    final attempted = <String>[];

    final result = await plan.install((List<String> arguments) async {
      final local = arguments[arguments.indexOf('forward') + 1];
      attempted.add(local);
      if (local == 'tcp:27184') {
        throw const AdbExceptionStub('control port busy');
      }
    });

    // The video tunnel was installed, the control tunnel failed, and the
    // failure did not stop the loop.
    expect(attempted, <String>['tcp:27183', 'tcp:27184']);
    expect(result.done, <AdbForward>[const AdbForward.samePort(27183)]);
    expect(result.failures, hasLength(1));
    expect(result.failures.single.forward, const AdbForward.samePort(27184));
    expect(result.isComplete, isFalse);
  });

  test('install failure on the video tunnel still attempts the control one',
      () async {
    final plan = wiredPlan();
    final attempted = <String>[];

    final result = await plan.install((List<String> arguments) async {
      final local = arguments[arguments.indexOf('forward') + 1];
      attempted.add(local);
      if (local == 'tcp:27183') {
        throw const AdbExceptionStub('27183 busy');
      }
    });

    expect(attempted, <String>['tcp:27183', 'tcp:27184']);
    expect(result.done, <AdbForward>[const AdbForward.samePort(27184)]);
    expect(result.failures.single.forward, const AdbForward.samePort(27183));
  });

  test('cleanup removes both tunnels when one removal fails', () async {
    // The exact failure mode the requirement calls out: 27184 cannot be
    // removed, and 27183 must be attempted anyway.
    final plan = wiredPlan();
    final removed = <String>[];

    final result = await plan.remove((List<String> arguments) async {
      removed.add(arguments.last);
      if (arguments.last == 'tcp:27184') {
        throw const AdbExceptionStub('device offline');
      }
    });

    expect(removed, <String>['tcp:27183', 'tcp:27184']);
    expect(result.done, <AdbForward>[const AdbForward.samePort(27183)]);
    expect(result.failures.single.forward, const AdbForward.samePort(27184));
  });

  test('cleanup is idempotent after a partial install', () async {
    // 27184 never installed and 27183's removal fails too: cleanup must still
    // attempt both tunnels instead of stopping at the first failure.
    final plan = wiredPlan();
    final attempted = <String>[];

    await plan.install((List<String> arguments) async {
      final local = arguments[arguments.indexOf('forward') + 1];
      attempted.add('install $local');
      if (local == 'tcp:27184') {
        throw const AdbExceptionStub('control port busy');
      }
    });

    final removed = <String>[];
    final result = await plan.remove((List<String> arguments) async {
      removed.add(arguments.last);
      throw const AdbExceptionStub('forward not found');
    });

    expect(attempted, <String>['install tcp:27183', 'install tcp:27184']);
    expect(removed, <String>['tcp:27183', 'tcp:27184']);
    // Both removals are treated as failed, and nothing escaped to the caller.
    expect(result.failures, hasLength(2));
    expect(result.done, isEmpty);
  });

  test('AdbForward equality is port based', () {
    expect(const AdbForward(27183, 27183), const AdbForward.samePort(27183));
    expect(
      const AdbForward(27183, 27183),
      isNot(const AdbForward(27184, 27184)),
    );
  });
}

/// Local stand-in for [AdbException] so this test does not depend on the
/// launcher's platform bindings.
class AdbExceptionStub implements Exception {
  const AdbExceptionStub(this.message);

  final String message;

  @override
  String toString() => 'AdbExceptionStub: $message';
}

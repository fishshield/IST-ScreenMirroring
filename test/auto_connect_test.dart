import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/cast/cast_session_state.dart';
import 'package:screen_cast_demo/src/discovery/auto_connect.dart';
import 'package:screen_cast_demo/src/discovery/cast_offer.dart';

class _FakeTarget implements AutoConnectTarget {
  _FakeTarget({
    this.autoConnectEnabled = true,
    this.pskHex = '',
  });

  @override
  bool autoConnectEnabled;

  CastStatus status = CastStatus.idle;

  @override
  CastStatus get castStatus => status;

  @override
  String pskHex;

  @override
  String statusMessage = 'boom';

  final List<CastOffer> connects = <CastOffer>[];
  final List<String> reports = <String>[];
  final List<bool> reportErrors = <bool>[];
  bool connectResult = true;

  @override
  Future<bool> connectToOffer(CastOffer offer) async {
    connects.add(offer);
    if (connectResult) {
      status = CastStatus.running;
    } else {
      status = CastStatus.error;
    }
    return connectResult;
  }

  @override
  void reportDiscovery(String message, {bool error = false}) {
    reports.add(message);
    reportErrors.add(error);
  }
}

const CastOffer _offer = CastOffer(ip: '192.168.1.134');

void main() {
  test('does nothing while the switch is off', () async {
    final target = _FakeTarget(autoConnectEnabled: false);
    final policy = AutoConnectPolicy(target: target);

    await policy.handleOffer(_offer);

    expect(target.connects, isEmpty);
    expect(target.reports.single, contains('自动连接未开启'));
  });

  test('ignores offers once a session is running', () async {
    final target = _FakeTarget()..status = CastStatus.running;
    final policy = AutoConnectPolicy(target: target);

    await policy.handleOffer(_offer);

    expect(target.connects, isEmpty);
    expect(target.reports, isEmpty);
  });

  test('a five-packet burst triggers exactly one connect attempt', () async {
    final target = _FakeTarget();
    var connected = 0;
    final policy = AutoConnectPolicy(
      target: target,
      onConnected: (CastOffer offer) => connected++,
    );

    for (var i = 0; i < 5; i++) {
      await policy.handleOffer(_offer);
    }

    expect(target.connects, hasLength(1));
    expect(connected, 1);
  });

  test('retries after the cooldown when still disconnected', () async {
    final target = _FakeTarget();
    target.connectResult = false;
    var now = DateTime(2026, 11, 17, 12);
    final policy = AutoConnectPolicy(
      target: target,
      clock: () => now,
      retryCooldown: const Duration(seconds: 8),
    );

    await policy.handleOffer(_offer);
    now = now.add(const Duration(seconds: 2));
    await policy.handleOffer(_offer);
    expect(target.connects, hasLength(1));

    now = now.add(const Duration(seconds: 7));
    await policy.handleOffer(_offer);
    expect(target.connects, hasLength(2));
  });

  test('required PSK without a configured key fails loudly, no connect',
      () async {
    final target = _FakeTarget();
    final failures = <String>[];
    final policy = AutoConnectPolicy(
      target: target,
      onFailed: (CastOffer offer, String message) => failures.add(message),
    );

    await policy.handleOffer(
      const CastOffer(ip: '192.168.1.134', pskRequired: true),
    );

    expect(target.connects, isEmpty);
    expect(failures.single, contains('PSK'));
    expect(target.reports.single, contains('PSK'));
    expect(target.reportErrors.single, isTrue);
  });

  test('required PSK with a configured key connects', () async {
    final target = _FakeTarget(pskHex: '00112233445566778899aabbccddeeff');
    final policy = AutoConnectPolicy(target: target);

    await policy.handleOffer(
      const CastOffer(ip: '192.168.1.134', pskRequired: true),
    );

    expect(target.connects, hasLength(1));
    expect(target.reports.last, contains('已自动连接'));
  });

  test('failed connect reports the session message', () async {
    final target = _FakeTarget()..connectResult = false;
    final failures = <String>[];
    final policy = AutoConnectPolicy(
      target: target,
      onFailed: (CastOffer offer, String message) => failures.add(message),
    );

    await policy.handleOffer(_offer);

    expect(failures.single, contains('boom'));
    expect(target.reportErrors.last, isTrue);
  });

  test('pskForOffer strips the key for a plaintext server', () {
    const plain = CastOffer(ip: '10.0.0.2', pskRequired: false);
    const secure = CastOffer(ip: '10.0.0.2', pskRequired: true);

    expect(pskForOffer(offer: plain, configuredPsk: 'aabb'), '');
    expect(pskForOffer(offer: secure, configuredPsk: 'aabb'), 'aabb');
  });
}

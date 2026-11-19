import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/transport/cast_transport.dart';

void main() {
  test('wired mode always uses loopback and ADB forward', () {    const config = CastTransportConfig(
      mode: CastTransportMode.wired,
      host: '192.168.1.23',
      port: 27183,
    );

    expect(config.effectiveHost, '127.0.0.1');
    expect(config.bindAddress, '127.0.0.1');
    expect(config.usesAdbForward, isTrue);
    expect(config.endpoint, '127.0.0.1:27183');
    expect(config.validate, returnsNormally);
  });

  test('wireless mode uses the phone LAN address without a forward', () {
    const config = CastTransportConfig(
      mode: CastTransportMode.wireless,
      host: ' 192.168.1.23 ',
      port: 27183,
    );

    expect(config.effectiveHost, '192.168.1.23');
    expect(config.bindAddress, '0.0.0.0');
    expect(config.usesAdbForward, isFalse);
    expect(config.endpoint, '192.168.1.23:27183');
    expect(config.validate, returnsNormally);
  });

  test('wireless mode rejects an empty or whitespace host', () {
    const empty = CastTransportConfig(
      mode: CastTransportMode.wireless,
      host: '',
    );
    const whitespace = CastTransportConfig(
      mode: CastTransportMode.wireless,
      host: '192.168.1.2 3',
    );

    expect(empty.validate, throwsArgumentError);
    expect(whitespace.validate, throwsArgumentError);
    expect(empty.hasUsableHost, isFalse);
  });

  test('direct mode connects to the phone and starts nothing over ADB', () {
    const config = CastTransportConfig(
      mode: CastTransportMode.direct,
      host: '192.168.1.134',
      port: 27183,
    );

    expect(config.effectiveHost, '192.168.1.134');
    expect(config.endpoint, '192.168.1.134:27183');
    expect(config.usesAdbForward, isFalse);
    expect(config.startsServerOverAdb, isFalse);
    expect(config.requiresLanHost, isTrue);
    expect(config.validate, returnsNormally);
  });

  test('direct mode still requires the phone LAN address', () {
    const empty = CastTransportConfig(mode: CastTransportMode.direct);
    expect(empty.validate, throwsArgumentError);
    expect(empty.hasUsableHost, isFalse);
    expect(empty.displayHost, '未填写手机 IP');
  });

  test('wireless mode keeps owning the ADB-side server start', () {
    const config = CastTransportConfig(
      mode: CastTransportMode.wireless,
      host: '192.168.1.23',
    );
    expect(config.startsServerOverAdb, isTrue);
    expect(config.usesAdbForward, isFalse);
  });

  test('rejects an invalid port', () {
    const config = CastTransportConfig(port: 80);
    expect(config.validate, throwsArgumentError);
  });

  test('targetFps accepts 0 (unlimited) and 1..240 only', () {
    expect(const CastTransportConfig(targetFps: 0).targetFps, 0);
    expect(const CastTransportConfig(targetFps: 60).validate, returnsNormally);
    expect(const CastTransportConfig(targetFps: -1).validate,
        throwsArgumentError);
    expect(const CastTransportConfig(targetFps: 241).validate,
        throwsArgumentError);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/config/app_config.dart';

void main() {
  test('missing file yields defaults (limit 60 fps off)', () async {
    final dir = await Directory.systemTemp.createTemp('scrc-config-test');
    addTearDown(() => dir.delete(recursive: true));
    final store = AppConfigStore(file: File('${dir.path}/config.json'));

    final config = await store.load();
    expect(config.limit60Fps, isFalse);
  });

  test('save/load round-trips the switch', () async {
    final dir = await Directory.systemTemp.createTemp('scrc-config-test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/nested/config.json');
    final store = AppConfigStore(file: file);

    await store.save(const AppConfig(limit60Fps: true));
    expect(await file.exists(), isTrue);
    expect((await store.load()).limit60Fps, isTrue);

    await store.save(const AppConfig(limit60Fps: false));
    expect((await store.load()).limit60Fps, isFalse);
  });

  test('malformed json falls back to defaults instead of throwing', () async {
    final dir = await Directory.systemTemp.createTemp('scrc-config-test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/config.json');
    await file.writeAsString('{ not json');

    final config = await AppConfigStore(file: file).load();
    expect(config.limit60Fps, isFalse);
  });

  test('unknown/mis-typed values are ignored', () async {
    final dir = await Directory.systemTemp.createTemp('scrc-config-test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/config.json');
    await file.writeAsString(
      jsonEncode(<String, Object?>{'limit60Fps': 'yes', 'future': 1}),
    );

    expect((await AppConfigStore(file: file).load()).limit60Fps, isFalse);
  });
}

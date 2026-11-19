import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/ffmpeg/decoded_frame.dart';
import 'package:screen_cast_demo/src/pipeline/cast_session.dart';
import 'package:screen_cast_demo/src/transport/cast_transport.dart';

/// Manual end-to-end check against a connected Android device.
///
/// Wired mode (default):
/// ```powershell
/// flutter test tool\device_e2e_test.dart
/// ```
///
/// Wireless/LAN mode:
/// ```powershell
/// $env:SCREEN_CAST_WIRELESS='1'
/// $env:SCREEN_CAST_HOST='192.168.1.134'
/// flutter test tool\device_e2e_test.dart
/// ```
///
/// It exercises the actual Dart host path: rootBundle server jar -> AdbLauncher
/// (push/app_process, optional forward) -> ScrcSocketClient -> NAL queue ->
/// FFmpeg.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'launches the real device server and decodes SCRC frames',
    () async {
      final wireless = Platform.environment['SCREEN_CAST_WIRELESS'] == '1';
      final host = Platform.environment['SCREEN_CAST_HOST'] ?? '';
      final session = CastSession(
        transportMode:
            wireless ? CastTransportMode.wireless : CastTransportMode.wired,
        host: host,
      );
      final frames = <DecodedFrame>[];
      final errors = <Object>[];
      final closed = Completer<void>();

      try {
        final info = await session.start(
          onFrame: frames.add,
          onError: (Object error, StackTrace stackTrace) {
            errors.add(error);
          },
          onClosed: () {
            if (!closed.isCompleted) {
              closed.complete();
            }
          },
        );
        // ignore: avoid_print
        print(
          'E2E connected: serial=${info.serial} endpoint=${info.endpoint} '
          'transport=${info.transportMode.name} decoder=${info.decoderBackend}',
        );

        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (frames.isEmpty &&
            errors.isEmpty &&
            !closed.isCompleted &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }

        expect(errors, isEmpty, reason: 'capture/socket errors');
        expect(frames, isNotEmpty, reason: 'no decoded frames received');
        expect(frames.first.width, 1280);
        expect(frames.first.height, 720);
        // ignore: avoid_print
        print(
          'E2E decoded ${frames.length} frame(s): '
          '${frames.first.width}x${frames.first.height}',
        );
      } finally {
        await session.stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

import 'dart:io';
import 'dart:typed_data';

import 'package:screen_cast_demo/src/ffmpeg/ffmpeg_decoder.dart';
import 'package:screen_cast_demo/src/ffmpeg/ffmpeg_runtime.dart';
import 'package:screen_cast_demo/src/protocol/scrc_packet_decoder.dart';

/// Decodes a raw SCRC capture file:
///
/// ```text
/// dart run tool/decode_scrc_capture.dart build/device-scrc.bin
/// ```
///
/// It also writes an Annex-B file to build/device-capture.h264 for external
/// inspection. This is a developer diagnostic, not part of the app runtime.
void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'usage: dart run tool/decode_scrc_capture.dart <raw-scrc-file>',
    );
    exitCode = 64;
    return;
  }

  final raw = File(args.single).readAsBytesSync();
  final packets = ScrcPacketDecoder().add(raw);
  stdout.writeln('SCRC bytes: ${raw.length}');
  stdout.writeln('Complete NAL packets: ${packets.length}');

  final annexB = BytesBuilder(copy: false);
  final nalTypes = <int, int>{};
  for (final packet in packets) {
    final type = packet.payload[0] & 0x1f;
    nalTypes[type] = (nalTypes[type] ?? 0) + 1;
    annexB
      ..add(const <int>[0, 0, 0, 1])
      ..add(packet.payload);
  }
  stdout.writeln('NAL types: $nalTypes');

  final output = File('build/device-capture.h264');
  output.writeAsBytesSync(annexB.takeBytes());
  stdout.writeln('Annex-B output: ${output.path}');

  final directory = FfmpegRuntime.findLibraryDirectory();
  if (directory == null) {
    stderr.writeln('FFmpeg DLLs not found; captured NALs were not decoded.');
    exitCode = 2;
    return;
  }

  final decoder = FfmpegDecoder.open(libraryDirectory: directory);
  var frameCount = 0;
  var width = 0;
  var height = 0;
  try {
    for (final packet in packets) {
      for (final frame in decoder.decode(packet.payload)) {
        frameCount++;
        width = frame.width;
        height = frame.height;
      }
    }
    for (final frame in decoder.flush()) {
      frameCount++;
      width = frame.width;
      height = frame.height;
    }
  } finally {
    decoder.dispose();
  }

  stdout.writeln(
    'Decoded frames: $frameCount'
    '${width > 0 ? ' (${width}x$height)' : ''}',
  );
  if (frameCount == 0) {
    exitCode = 1;
  }
}

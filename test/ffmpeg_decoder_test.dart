import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/ffmpeg/decoded_frame.dart';
import 'package:screen_cast_demo/src/ffmpeg/ffmpeg_decoder.dart';
import 'package:screen_cast_demo/src/ffmpeg/ffmpeg_runtime.dart';

void main() {
  final libraryDirectory = FfmpegRuntime.findLibraryDirectory();

  test(
    'decodes a baseline H.264 Annex-B sample into YUV420p frames',
    () {
      final decoder = FfmpegDecoder.open(
        libraryDirectory: libraryDirectory,
      );
      try {
        final bytes = File(
          'test/assets/sample_320x180.h264',
        ).readAsBytesSync();
        final nals = _splitAnnexB(bytes);
        expect(nals, isNotEmpty);

        final frames = <DecodedFrame>[];
        for (final nal in nals) {
          frames.addAll(decoder.decode(nal));
        }
        frames.addAll(decoder.flush());

        expect(frames, isNotEmpty);
        final first = frames.first;
        expect(first.width, 320);
        expect(first.height, 180);
        expect(first.isYuv420p, isTrue);
        expect(first.y, hasLength(greaterThan(320 * 180 ~/ 2)));
        expect(first.y.any((int byte) => byte != 0), isTrue);
        // ignore: avoid_print
        print(
          'FFmpeg decoded ${frames.length} frame(s), '
          'first=${first.width}x${first.height} '
          'format=${first.pixelFormat} '
          'dlls=${libraryDirectory ?? "process-search"}',
        );
      } finally {
        decoder.dispose();
      }
    },
    skip: libraryDirectory == null
        ? 'FFmpeg DLLs missing; run tool/fetch_ffmpeg.ps1'
        : false,
  );
}

List<Uint8List> _splitAnnexB(Uint8List bytes) {
  final starts = <int>[];
  final payloadStarts = <int>[];
  var index = 0;

  while (index + 2 < bytes.length) {
    if (bytes[index] == 0 && bytes[index + 1] == 0) {
      if (bytes[index + 2] == 1) {
        starts.add(index);
        payloadStarts.add(index + 3);
        index += 3;
        continue;
      }
      if (index + 3 < bytes.length &&
          bytes[index + 2] == 0 &&
          bytes[index + 3] == 1) {
        starts.add(index);
        payloadStarts.add(index + 4);
        index += 4;
        continue;
      }
    }
    index++;
  }

  final result = <Uint8List>[];
  for (var i = 0; i < payloadStarts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] : bytes.length;
    if (end > payloadStarts[i]) {
      result.add(Uint8List.sublistView(bytes, payloadStarts[i], end));
    }
  }
  return result;
}

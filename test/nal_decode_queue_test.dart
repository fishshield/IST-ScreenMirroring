import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/pipeline/nal_decode_queue.dart';

Uint8List nal(int header) => Uint8List.fromList(<int>[header, 0x00, 0x00]);
Uint8List idr() => nal(0x65); // NAL type 5 (IDR slice)
Uint8List pFrame() => nal(0x41); // NAL type 1 (non-IDR slice)
Uint8List sps() => nal(0x67); // NAL type 7
Uint8List pps() => nal(0x68); // NAL type 8

void main() {
  test('overflow clears the backlog and waits for an IDR', () async {
    final queue = NalDecodeQueue(
      capacity: 2,
      idrWaitTimeout: const Duration(seconds: 30),
    );
    queue.add(pFrame());
    queue.add(pFrame());
    queue.add(pFrame()); // hits the bound

    expect(queue.waitingForIdr, isTrue);
    expect(queue.overflowEvents, 1);
    expect(queue.dropped, 2);
    expect(queue.length, 0);

    // Everything that is not a keyframe is discarded while waiting.
    queue.add(pFrame());
    queue.add(pFrame());
    expect(queue.length, 0);
    expect(queue.waitingForIdr, isTrue);

    // SPS/PPS are kept and replayed in front of the IDR.
    queue.add(sps());
    queue.add(pps());
    queue.add(idr());
    expect(queue.waitingForIdr, isFalse);

    expect((await queue.take())!, sps());
    expect((await queue.take())!, pps());
    expect((await queue.take())!, idr());

    // Normal delivery continues after the resumption.
    queue.add(pFrame());
    expect((await queue.take())!, pFrame());
    queue.close();
  });

  test('an IDR without preceding SPS/PPS also resumes decoding', () async {
    final queue = NalDecodeQueue(capacity: 1);
    queue.add(pFrame());
    queue.add(pFrame()); // overflow
    expect(queue.waitingForIdr, isTrue);

    queue.add(idr());
    expect(queue.waitingForIdr, isFalse);
    expect((await queue.take())!, idr());
    queue.close();
  });

  test('a slow IDR keeps waiting instead of resetting anything', () async {
    final queue = NalDecodeQueue(
      capacity: 1,
      idrWaitTimeout: const Duration(milliseconds: 40),
    );
    queue.add(pFrame());
    queue.add(pFrame()); // overflow
    await Future<void>.delayed(const Duration(milliseconds: 90));

    expect(queue.waitingForIdr, isTrue, reason: 'timeout must not give up');

    queue.add(sps());
    queue.add(idr());
    expect(queue.waitingForIdr, isFalse);
    expect((await queue.take())!, sps());
    expect((await queue.take())!, idr());
    queue.close();
  });

  test('a second overflow adds another episode', () async {
    final queue = NalDecodeQueue(capacity: 1);
    queue.add(pFrame());
    queue.add(pFrame());
    queue.add(idr());
    expect(queue.overflowEvents, 1);
    expect((await queue.take())!, idr());

    queue.add(pFrame());
    queue.add(pFrame());
    expect(queue.overflowEvents, 2);
    expect(queue.waitingForIdr, isTrue);
    queue.close();
  });

  test('close returns null to a blocked consumer', () async {
    final queue = NalDecodeQueue(capacity: 1);
    final pending = queue.take();
    queue.close();
    expect(await pending, isNull);
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/discovery/cast_offer.dart';

void main() {
  group('CastOffer.tryParse', () {
    test('accepts the exact payload the Android beacon sends', () {
      const raw = '{"type":"screencast-offer","ip":"192.168.1.134",'
          '"videoPort":27183,"controlPort":27184,"pskRequired":true}';
      final offer = CastOffer.tryParse(raw);
      expect(offer, isNotNull);
      expect(offer!.ip, '192.168.1.134');
      expect(offer.videoPort, 27183);
      expect(offer.controlPort, 27184);
      expect(offer.pskRequired, isTrue);
    });

    test('plaintext server advertises pskRequired=false', () {
      final offer = CastOffer.tryParse(
        CastOffer(ip: '10.0.0.7', pskRequired: false).encode(),
      );
      expect(offer?.pskRequired, isFalse);
      expect(offer?.ip, '10.0.0.7');
    });

    test('encoding round-trips', () {
      const offer = CastOffer(
        ip: '192.168.1.5',
        videoPort: 28000,
        controlPort: 28001,
        pskRequired: true,
      );
      expect(CastOffer.tryParse(offer.encode()), offer);
      final map = jsonDecode(offer.encode()) as Map<String, dynamic>;
      expect(map['type'], CastOffer.type);
    });

    test('rejects a different message type', () {
      expect(
        CastOffer.tryParse(
          '{"type":"something-else","ip":"192.168.1.5",'
          '"videoPort":27183,"controlPort":27184}',
        ),
        isNull,
      );
    });

    test('rejects malformed json and non-object payloads', () {
      expect(CastOffer.tryParse('not json'), isNull);
      expect(CastOffer.tryParse('[]'), isNull);
      expect(CastOffer.tryParse('null'), isNull);
    });

    test('rejects non-IPv4 and missing addresses', () {
      expect(
        CastOffer.tryParse(
          '{"type":"screencast-offer","ip":"example.lan",'
          '"videoPort":27183,"controlPort":27184}',
        ),
        isNull,
      );
      expect(
        CastOffer.tryParse(
          '{"type":"screencast-offer","ip":"::1",'
          '"videoPort":27183,"controlPort":27184}',
        ),
        isNull,
      );
      expect(
        CastOffer.tryParse(
          '{"type":"screencast-offer","videoPort":27183,'
          '"controlPort":27184}',
        ),
        isNull,
      );
    });

    test('rejects out-of-range or conflicting ports', () {
      CastOffer? parse(int video, int control) => CastOffer.tryParse(
            '{"type":"screencast-offer","ip":"192.168.1.5",'
            '"videoPort":$video,"controlPort":$control}',
          );
      expect(parse(80, 27184), isNull, reason: 'privileged port');
      expect(parse(70000, 27184), isNull, reason: 'out of range');
      expect(parse(27183, 27183), isNull, reason: 'same port');
      expect(parse(27183, 27184), isNotNull);
    });

    test('pskRequired defaults to false when absent', () {
      final offer = CastOffer.tryParse(
        '{"type":"screencast-offer","ip":"192.168.1.5",'
        '"videoPort":27183,"controlPort":27184}',
      );
      expect(offer?.pskRequired, isFalse);
    });
  });
}

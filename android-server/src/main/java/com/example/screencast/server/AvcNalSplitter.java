package com.example.screencast.server;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Splits one MediaCodec H.264 output buffer into individual NAL units.
 *
 * <p>Android encoders normally emit Annex-B. A length-prefixed fallback is
 * included because vendor encoders occasionally vary. The SCRC protocol still
 * receives exactly one NAL unit per packet.
 */
final class AvcNalSplitter {
    private AvcNalSplitter() {
    }

    static List<byte[]> split(byte[] data) {
        if (data == null || data.length == 0) {
            return Collections.emptyList();
        }

        final List<byte[]> annexB = splitAnnexB(data);
        if (!annexB.isEmpty()) {
            return annexB;
        }

        final List<byte[]> lengthPrefixed = trySplitLengthPrefixed(data);
        if (!lengthPrefixed.isEmpty()) {
            return lengthPrefixed;
        }

        // Last-resort compatibility: treat the buffer as one raw NAL. The
        // caller logs this so a malformed stream does not fail silently.
        final byte[] single = new byte[data.length];
        System.arraycopy(data, 0, single, 0, data.length);
        return Collections.singletonList(single);
    }

    private static List<byte[]> splitAnnexB(byte[] data) {
        final List<int[]> ranges = new ArrayList<>();
        int index = 0;
        while (index + 3 <= data.length) {
            final int payloadStart;
            if (isThreeByteStartCode(data, index)) {
                payloadStart = index + 3;
                index = payloadStart;
            } else if (isFourByteStartCode(data, index)) {
                payloadStart = index + 4;
                index = payloadStart;
            } else {
                index++;
                continue;
            }

            int next = payloadStart;
            while (next < data.length) {
                if (isThreeByteStartCode(data, next) || isFourByteStartCode(data, next)) {
                    break;
                }
                next++;
            }
            if (payloadStart < next) {
                ranges.add(new int[]{payloadStart, next});
            }
            if (next <= index) {
                break;
            }
            index = next;
        }

        if (ranges.isEmpty()) {
            return Collections.emptyList();
        }

        final List<byte[]> result = new ArrayList<>(ranges.size());
        for (int[] range : ranges) {
            final byte[] nal = new byte[range[1] - range[0]];
            System.arraycopy(data, range[0], nal, 0, nal.length);
            result.add(nal);
        }
        return result;
    }

    private static List<byte[]> trySplitLengthPrefixed(byte[] data) {
        final List<byte[]> result = new ArrayList<>();
        int offset = 0;
        while (offset + 4 <= data.length) {
            final int length = readInt(data, offset);
            if (length <= 0 || offset + 4 + length > data.length) {
                return Collections.emptyList();
            }
            final byte[] nal = new byte[length];
            System.arraycopy(data, offset + 4, nal, 0, length);
            result.add(nal);
            offset += 4 + length;
        }
        return offset == data.length ? result : Collections.emptyList();
    }

    private static int readInt(byte[] data, int offset) {
        return ((data[offset] & 0xff) << 24)
            | ((data[offset + 1] & 0xff) << 16)
            | ((data[offset + 2] & 0xff) << 8)
            | (data[offset + 3] & 0xff);
    }

    private static boolean isThreeByteStartCode(byte[] data, int offset) {
        return offset + 2 < data.length
            && data[offset] == 0
            && data[offset + 1] == 0
            && data[offset + 2] == 1;
    }

    private static boolean isFourByteStartCode(byte[] data, int offset) {
        return offset + 3 < data.length
            && data[offset] == 0
            && data[offset + 1] == 0
            && data[offset + 2] == 0
            && data[offset + 3] == 1;
    }
}

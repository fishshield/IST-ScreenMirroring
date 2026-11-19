package com.example.screencast.server;

import java.io.IOException;
import java.io.OutputStream;

/**
 * Writes one SCRC frame per H.264 NAL unit.
 *
 * <pre>
 * 4 bytes: 0x53435243 ("SCRC"), big-endian
 * 4 bytes: payload length, big-endian
 * N bytes: one H.264 NAL unit, no Annex-B start code
 * </pre>
 *
 * <p>This class only owns transport framing. It does not transform the NAL
 * payload and does not emit SPS/PPS itself; the capture/codec layer must write
 * those NALs before the first IDR.
 */
public final class ScrcPacketWriter implements NalUnitSink, AutoCloseable {
    public static final int MAGIC = 0x53435243;
    public static final int HEADER_BYTES = 8;

    private final OutputStream output;
    private final int maxPayloadBytes;
    private final Object writeLock = new Object();

    public ScrcPacketWriter(OutputStream output, int maxPayloadBytes) {
        if (output == null) {
            throw new IllegalArgumentException("output must not be null");
        }
        if (maxPayloadBytes <= 0) {
            throw new IllegalArgumentException("maxPayloadBytes must be positive");
        }
        this.output = output;
        this.maxPayloadBytes = maxPayloadBytes;
    }

    @Override
    public void writeNalUnit(byte[] nalUnit) throws IOException {
        if (nalUnit == null || nalUnit.length == 0) {
            throw new IOException("NAL unit must not be empty");
        }
        if (nalUnit.length > maxPayloadBytes) {
            throw new IOException(
                "NAL unit of " + nalUnit.length + " bytes exceeds the "
                    + maxPayloadBytes + " byte limit"
            );
        }

        final byte[] header = new byte[HEADER_BYTES];
        writeInt(header, 0, MAGIC);
        writeInt(header, 4, nalUnit.length);

        synchronized (writeLock) {
            output.write(header);
            output.write(nalUnit);
            output.flush();
        }
    }

    @Override
    public void close() throws IOException {
        synchronized (writeLock) {
            output.close();
        }
    }

    private static void writeInt(byte[] target, int offset, int value) {
        target[offset] = (byte) (value >>> 24);
        target[offset + 1] = (byte) (value >>> 16);
        target[offset + 2] = (byte) (value >>> 8);
        target[offset + 3] = (byte) value;
    }
}

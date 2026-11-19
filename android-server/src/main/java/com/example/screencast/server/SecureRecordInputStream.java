package com.example.screencast.server;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.security.GeneralSecurityException;
import java.util.Arrays;

/**
 * Record-layer decryptor: reads length-prefixed encrypted records from any
 * {@link InputStream} and exposes the concatenated plaintext.
 *
 * <p>Authentication failures are reported as {@link IOException}, so callers
 * (the control server) treat a tampered or wrong-PSK record exactly like a
 * broken connection: they log it and stop injecting, never crash the video
 * session.
 */
final class SecureRecordInputStream extends InputStream {
    private final InputStream in;
    private final PskCipher cipher;

    private byte[] plaintext = new byte[0];
    private int position = 0;
    private int limit = 0;

    SecureRecordInputStream(InputStream in, PskCipher cipher) {
        this.in = in;
        this.cipher = cipher;
    }

    @Override
    public int read() throws IOException {
        if (!ensurePlaintext()) {
            return -1;
        }
        return plaintext[position++] & 0xFF;
    }

    @Override
    public int read(byte[] destination, int offset, int length) throws IOException {
        if (length == 0) {
            return 0;
        }
        if (!ensurePlaintext()) {
            return -1;
        }
        final int available = limit - position;
        final int copied = Math.min(length, available);
        System.arraycopy(plaintext, position, destination, offset, copied);
        position += copied;
        return copied;
    }

    @Override
    public int available() {
        return limit - position;
    }

    private boolean ensurePlaintext() throws IOException {
        while (position >= limit) {
            if (!readRecord()) {
                return false;
            }
        }
        return true;
    }

    /** Returns false on a clean EOF at a record boundary. */
    private boolean readRecord() throws IOException {
        final int b0 = in.read();
        if (b0 < 0) {
            return false;
        }
        final int b1 = readByte();
        final int b2 = readByte();
        final int b3 = readByte();
        final int length = ((b0 & 0xFF) << 24)
            | ((b1 & 0xFF) << 16)
            | ((b2 & 0xFF) << 8)
            | (b3 & 0xFF);

        final int maxLength = SecureRecordOutputStream.MAX_RECORD_BYTES
            + SecureRecordOutputStream.OVERHEAD_BYTES;
        if (length < SecureRecordOutputStream.OVERHEAD_BYTES || length > maxLength) {
            throw new IOException(
                "Invalid encrypted record length " + length
                    + " (expected " + SecureRecordOutputStream.OVERHEAD_BYTES
                    + ".." + maxLength + ")"
            );
        }

        final byte[] record = new byte[length];
        readFully(record);
        final byte[] nonce = Arrays.copyOfRange(record, 0, PskCipher.NONCE_BYTES);
        final byte[] sealed = Arrays.copyOfRange(
            record,
            PskCipher.NONCE_BYTES,
            length
        );
        try {
            plaintext = cipher.open(nonce, sealed);
        } catch (GeneralSecurityException error) {
            throw new IOException(
                "GCM authentication failed (wrong PSK or tampered record)",
                error
            );
        }
        position = 0;
        limit = plaintext.length;
        // Empty records are legal but never produced; loop again for safety.
        return true;
    }

    private int readByte() throws IOException {
        final int value = in.read();
        if (value < 0) {
            throw new EOFException("Truncated encrypted record header");
        }
        return value;
    }

    private void readFully(byte[] destination) throws IOException {
        int offset = 0;
        while (offset < destination.length) {
            final int read = in.read(destination, offset, destination.length - offset);
            if (read < 0) {
                throw new EOFException("Truncated encrypted record payload");
            }
            offset += read;
        }
    }
}

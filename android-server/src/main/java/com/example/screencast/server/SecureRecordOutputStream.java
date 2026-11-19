package com.example.screencast.server;

import java.io.IOException;
import java.io.OutputStream;
import java.security.GeneralSecurityException;
import java.util.Arrays;

/**
 * Record-layer encryptor: wraps any {@link OutputStream} and turns every write
 * into one or more encrypted records.
 *
 * <p>Record framing (matches {@code lib/src/transport/secure_channel.dart}):
 *
 * <pre>
 * +----------------+----------------+------------------+-----------+
 * | length: uint32 | nonce: 12 bytes| ciphertext       | tag: 16 B |
 * +----------------+----------------+------------------+-----------+
 * </pre>
 *
 * <p>The length field covers nonce + ciphertext + tag. This class never parses
 * the bytes it carries, so SCRC framing is untouched.
 */
final class SecureRecordOutputStream extends OutputStream {
    static final int MAX_RECORD_BYTES = 64 * 1024;
    static final int OVERHEAD_BYTES = PskCipher.NONCE_BYTES + PskCipher.TAG_BYTES;

    private final OutputStream out;
    private final PskCipher cipher;

    SecureRecordOutputStream(OutputStream out, PskCipher cipher) {
        this.out = out;
        this.cipher = cipher;
    }

    @Override
    public void write(int b) throws IOException {
        write(new byte[] {(byte) b}, 0, 1);
    }

    @Override
    public void write(byte[] bytes, int offset, int length) throws IOException {
        if (length <= 0) {
            return;
        }
        int cursor = offset;
        final int end = offset + length;
        while (cursor < end) {
            final int chunk = Math.min(MAX_RECORD_BYTES, end - cursor);
            final byte[] plaintext = Arrays.copyOfRange(
                bytes,
                cursor,
                cursor + chunk
            );
            final byte[] nonce = cipher.newNonce();
            final byte[] sealed;
            try {
                sealed = cipher.seal(nonce, plaintext);
            } catch (GeneralSecurityException error) {
                throw new IOException("GCM encrypt failed", error);
            }
            writeInt(PskCipher.NONCE_BYTES + sealed.length);
            out.write(nonce);
            out.write(sealed);
            cursor += chunk;
        }
        out.flush();
    }

    private void writeInt(int value) throws IOException {
        out.write((value >>> 24) & 0xFF);
        out.write((value >>> 16) & 0xFF);
        out.write((value >>> 8) & 0xFF);
        out.write(value & 0xFF);
    }

    @Override
    public void flush() throws IOException {
        out.flush();
    }

    @Override
    public void close() throws IOException {
        out.close();
    }
}

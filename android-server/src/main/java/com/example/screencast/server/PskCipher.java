package com.example.screencast.server;

import java.security.GeneralSecurityException;
import java.security.SecureRandom;

import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * AES-GCM with a pre-shared key.
 *
 * <p>Mirror of {@code lib/src/crypto/psk_cipher.dart}. This class is the only
 * place on the Android side that touches key material; the record streams and
 * both protocols stay unaware of it.
 *
 * <p>Keys are supplied as hex (32/48/64 characters = AES-128/192/256). An empty
 * value means "no PSK": the record layer degrades to plaintext.
 */
final class PskCipher {
    static final int NONCE_BYTES = 12;
    static final int TAG_BYTES = 16;
    static final int TAG_BITS = TAG_BYTES * 8;

    private final SecretKeySpec key;
    private final SecureRandom random = new SecureRandom();

    private PskCipher(SecretKeySpec key) {
        this.key = key;
    }

    static boolean isConfigured(String hex) {
        return hex != null && !hex.trim().isEmpty();
    }

    static PskCipher fromHex(String hex) {
        final byte[] bytes = parseHex(hex);
        return new PskCipher(new SecretKeySpec(bytes, "AES"));
    }

    /** Returns a human-readable reason, or null when valid/empty. */
    static String validateHex(String hex) {
        if (hex == null || hex.trim().isEmpty()) {
            return null;
        }
        final String normalized = hex.trim();
        if ((normalized.length() & 1) != 0) {
            return "psk-hex must have an even number of characters";
        }
        if (!normalized.matches("[0-9a-fA-F]+")) {
            return "psk-hex must contain only hexadecimal characters";
        }
        final int bytes = normalized.length() / 2;
        if (bytes != 16 && bytes != 24 && bytes != 32) {
            return "psk-hex must be 16, 24 or 32 bytes (32/48/64 hex characters)";
        }
        return null;
    }

    static byte[] parseHex(String hex) {
        final String normalized = hex == null ? "" : hex.trim();
        final String problem = validateHex(normalized);
        if (problem != null) {
            throw new IllegalArgumentException(problem);
        }
        final byte[] bytes = new byte[normalized.length() / 2];
        for (int index = 0; index < bytes.length; index++) {
            bytes[index] = (byte) Integer.parseInt(
                normalized.substring(index * 2, index * 2 + 2),
                16
            );
        }
        return bytes;
    }

    int keyLengthBytes() {
        return key.getEncoded().length;
    }

    byte[] newNonce() {
        final byte[] nonce = new byte[NONCE_BYTES];
        random.nextBytes(nonce);
        return nonce;
    }

    /** Returns {@code ciphertext || tag}. */
    byte[] seal(byte[] nonce, byte[] plaintext) throws GeneralSecurityException {
        final Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(
            Cipher.ENCRYPT_MODE,
            key,
            new GCMParameterSpec(TAG_BITS, nonce)
        );
        return cipher.doFinal(plaintext);
    }

    /** Accepts {@code ciphertext || tag}; throws on any tampering. */
    byte[] open(byte[] nonce, byte[] sealed) throws GeneralSecurityException {
        final Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(
            Cipher.DECRYPT_MODE,
            key,
            new GCMParameterSpec(TAG_BITS, nonce)
        );
        return cipher.doFinal(sealed);
    }
}

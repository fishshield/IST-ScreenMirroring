import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Raised for a bad PSK, a malformed record, or a failed GCM authentication.
class PskException implements Exception {
  const PskException(this.message);

  final String message;

  @override
  String toString() => 'PskException: $message';
}

/// AES-GCM with a pre-shared key.
///
/// This is the only place the project touches key material or a cipher; the
/// record layer ([SecureChannel]) and both protocols stay oblivious to it.
///
/// Keys are supplied as hex: 32, 48 or 64 hex characters (16, 24 or 32 bytes,
/// i.e. AES-128/192/256). An empty string means "no PSK" and the record layer
/// degrades to plaintext with a warning.
class PskCipher {
  PskCipher._(this._keyBytes, this._algorithm)
      : _secretKey = SecretKey(_keyBytes);

  /// GCM nonce size mandated by the record format.
  static const int nonceBytes = 12;

  /// GCM authentication tag size.
  static const int tagBytes = 16;

  final Uint8List _keyBytes;
  final AesGcm _algorithm;
  final SecretKey _secretKey;

  /// Parses [hex] into a cipher. Returns null when [hex] is blank, which means
  /// the caller wants an unencrypted channel.
  static PskCipher? fromHex(String hex) {
    final normalized = hex.trim();
    if (normalized.isEmpty) {
      return null;
    }
    final keyBytes = parseHex(normalized);
    return PskCipher._(keyBytes, algorithmForLength(keyBytes.length));
  }

  /// Returns a human-readable reason, or null when [hex] is acceptable
  /// (including the empty "no PSK" case).
  static String? validateHex(String hex) {
    final normalized = hex.trim();
    if (normalized.isEmpty) {
      return null;
    }
    if (normalized.length.isOdd) {
      return 'PSK hex must have an even number of characters.';
    }
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(normalized)) {
      return 'PSK must contain only hexadecimal characters (0-9, a-f).';
    }
    final length = normalized.length ~/ 2;
    if (length != 16 && length != 24 && length != 32) {
      return 'PSK must be 16, 24 or 32 bytes (32/48/64 hex characters).';
    }
    return null;
  }

  static Uint8List parseHex(String hex) {
    final normalized = hex.trim();
    final problem = validateHex(normalized);
    if (problem != null) {
      throw PskException(problem);
    }
    final bytes = Uint8List(normalized.length ~/ 2);
    for (var index = 0; index < bytes.length; index++) {
      final pair = normalized.substring(index * 2, index * 2 + 2);
      bytes[index] = int.parse(pair, radix: 16);
    }
    return bytes;
  }

  static AesGcm algorithmForLength(int keyBytes) {
    switch (keyBytes) {
      case 16:
        return AesGcm.with128bits();
      case 24:
        return AesGcm.with192bits();
      case 32:
        return AesGcm.with256bits();
      default:
        throw PskException(
          'Unsupported PSK length $keyBytes bytes; use 16, 24 or 32.',
        );
    }
  }

  int get keyLengthBytes => _keyBytes.length;

  /// Fresh random nonce for one record.
  Uint8List newNonce() {
    final nonce = _algorithm.newNonce();
    return Uint8List.fromList(nonce);
  }

  /// Encrypts [plaintext] and returns `ciphertext || tag`.
  Future<Uint8List> seal(Uint8List nonce, Uint8List plaintext) async {
    if (nonce.length != nonceBytes) {
      throw PskException('Nonce must be $nonceBytes bytes, got ${nonce.length}.');
    }
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: _secretKey,
      nonce: nonce,
    );
    final tag = box.mac.bytes;
    final sealed = Uint8List(box.cipherText.length + tag.length);
    sealed.setRange(0, box.cipherText.length, box.cipherText);
    sealed.setRange(box.cipherText.length, sealed.length, tag);
    return sealed;
  }

  /// Decrypts `ciphertext || tag`, throwing [PskException] on any tampering.
  Future<Uint8List> open(Uint8List nonce, Uint8List sealed) async {
    if (nonce.length != nonceBytes) {
      throw PskException('Nonce must be $nonceBytes bytes, got ${nonce.length}.');
    }
    if (sealed.length < tagBytes) {
      throw PskException('Record is too short to hold a GCM tag.');
    }
    final cipherText = Uint8List.sublistView(
      sealed,
      0,
      sealed.length - tagBytes,
    );
    final tag = Uint8List.sublistView(sealed, sealed.length - tagBytes);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(tag));
    try {
      final clear = await _algorithm.decrypt(box, secretKey: _secretKey);
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const PskException(
        'GCM authentication failed: wrong PSK or tampered record.',
      );
    }
  }

  /// Best-effort wipe of the parsed key material.
  void dispose() {
    _keyBytes.fillRange(0, _keyBytes.length, 0);
  }
}

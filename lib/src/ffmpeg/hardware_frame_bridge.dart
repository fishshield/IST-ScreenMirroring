import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Synchronous bridge to the Windows plugin's D3D11 device and overlay.
///
/// The D3D11VA path copies a decoded texture into the overlay with
/// `CopySubresourceRegion` **inside** the FFmpeg receive call, while the
/// `AVFrame` still owns the texture. A MethodChannel round trip would be
/// asynchronous, so these entry points are plain C exports called through
/// `dart:ffi` instead.
///
/// The plugin DLL is already loaded by Flutter; opening the same file by path
/// returns that module, so the exports see the live overlay instance.
class HardwareFrameBridge {
  HardwareFrameBridge._(this._acquire, this._release, this._copy);

  static const String _libraryName = 'screen_cast_windows_plugin.dll';
  static const int _errorBufferBytes = 512;

  final int Function(Pointer<Pointer<Void>>, Pointer<Pointer<Void>>) _acquire;
  final void Function(Pointer<Void>, Pointer<Void>) _release;
  final int Function(Pointer<Void>, int, int, int, Pointer<Uint8>, int) _copy;

  /// Opens the bridge, or returns null on hosts without the plugin.
  static HardwareFrameBridge? tryOpen({String? libraryPath}) {
    if (!Platform.isWindows) {
      return null;
    }
    final path = libraryPath ?? _defaultLibraryPath();
    try {
      final library = DynamicLibrary.open(path);
      return HardwareFrameBridge._(
        library.lookupFunction<
            Int32 Function(Pointer<Pointer<Void>>, Pointer<Pointer<Void>>),
            int Function(
                Pointer<Pointer<Void>>, Pointer<Pointer<Void>>)>(
          'screencast_hw_acquire_device',
        ),
        library.lookupFunction<Void Function(Pointer<Void>, Pointer<Void>),
            void Function(Pointer<Void>, Pointer<Void>)>(
          'screencast_hw_release_device',
        ),
        library.lookupFunction<
            Int32 Function(Pointer<Void>, Int64, Int32, Int32, Pointer<Uint8>,
                Int32),
            int Function(Pointer<Void>, int, int, int, Pointer<Uint8>,
                int)>(
          'screencast_hw_copy_texture',
        ),
      );
    } catch (error) {
      debugPrint('[hwaccel] native bridge unavailable: $error');
      return null;
    }
  }

  static String _defaultLibraryPath() {
    final executable = File(Platform.resolvedExecutable);
    return '${executable.parent.path}${Platform.pathSeparator}$_libraryName';
  }

  /// One reference each to the overlay's `ID3D11Device` and immediate context,
  /// or null when no overlay exists yet. Ownership transfers to FFmpeg's
  /// `AVD3D11VADeviceContext`; use [releaseDevice] when setup is abandoned.
  ({int device, int context})? acquireDevice() {
    final deviceOut = calloc<Pointer<Void>>();
    final contextOut = calloc<Pointer<Void>>();
    try {
      if (_acquire(deviceOut, contextOut) != 0 ||
          deviceOut.value == nullptr ||
          contextOut.value == nullptr) {
        return null;
      }
      return (
        device: deviceOut.value.address,
        context: contextOut.value.address,
      );
    } finally {
      calloc.free(deviceOut);
      calloc.free(contextOut);
    }
  }

  void releaseDevice(int device, int context) {
    _release(
      Pointer<Void>.fromAddress(device),
      Pointer<Void>.fromAddress(context),
    );
  }

  /// Copies one NV12 slice into the overlay.
  ///
  /// Returns 0 on success, 1 when the texture belongs to another D3D11 device
  /// (the caller must download the frame instead) and 2 on failure.
  int copyTexture({
    required int texture,
    required int slice,
    required int width,
    required int height,
    StringBuffer? error,
  }) {
    final errorBuffer = calloc<Uint8>(_errorBufferBytes);
    try {
      final result = _copy(
        Pointer<Void>.fromAddress(texture),
        slice,
        width,
        height,
        errorBuffer,
        _errorBufferBytes,
      );
      if (result != 0 && error != null) {
        error.write(errorBuffer.cast<Utf8>().toDartString().trim());
      }
      return result;
    } finally {
      calloc.free(errorBuffer);
    }
  }
}

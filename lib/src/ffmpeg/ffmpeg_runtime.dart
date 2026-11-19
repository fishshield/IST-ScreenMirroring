import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

class FfmpegException implements Exception {
  const FfmpegException(this.message);

  final String message;

  @override
  String toString() => 'FfmpegException: $message';
}

/// Entry points for locating and loading the FFmpeg runtime.
class FfmpegRuntime {
  FfmpegRuntime._();

  static String? findLibraryDirectory() =>
      FfmpegLibraries.findLibraryDirectory();

  static FfmpegLibraries open({String? libraryDirectory}) =>
      FfmpegLibraries.open(libraryDirectory: libraryDirectory);
}

/// Native function table for the small subset of libavcodec/libavutil used by
/// the demo decoder.
///
/// The ABI deliberately treats AVCodecContext, AVCodecParserContext, AVPacket
/// and AVCodec as opaque pointers. Only AVFrame's stable prefix is mirrored.
class FfmpegLibraries {
  FfmpegLibraries._({
    required DynamicLibrary avutil,
    required DynamicLibrary swresample,
    required DynamicLibrary avcodec,
  })  : _avutil = avutil,
        _avcodec = avcodec,
        _loadedLibraries = <DynamicLibrary>[avutil, swresample, avcodec] {
    _bind();
  }

  // Strong references keep all DLL modules loaded for the lifetime of the
  // function table.
  final DynamicLibrary _avutil;
  final DynamicLibrary _avcodec;
  final List<DynamicLibrary> _loadedLibraries;

  int get loadedLibraryCount => _loadedLibraries.length;

  late final Pointer<Uint8> Function(int size) avMallocz;
  late final void Function(Pointer<Uint8> pointer) avFree;

  late final Pointer<Void> Function(int codecId) findDecoder;
  late final Pointer<Void> Function(Pointer<Void> codec) allocContext;
  late final int Function(
    Pointer<Void> context,
    Pointer<Void> codec,
    Pointer<Void> options,
  ) openContext;
  late final void Function(Pointer<Pointer<Void>> context) freeContext;
  late final int Function(Pointer<Void> context, Pointer<Void> packet)
      sendPacket;
  late final int Function(Pointer<Void> context, Pointer<Void> frame)
      receiveFrame;

  late final Pointer<Void> Function() packetAlloc;
  late final void Function(Pointer<Void> packet) packetUnref;
  late final void Function(Pointer<Pointer<Void>> packet) packetFree;
  late final int Function(
    Pointer<Void> packet,
    Pointer<Uint8> data,
    int size,
  ) packetFromData;

  late final Pointer<Void> Function() frameAlloc;
  late final void Function(Pointer<Void> frame) frameUnref;
  late final void Function(Pointer<Pointer<Void>> frame) frameFree;

  // --- hardware acceleration (D3D11VA) -------------------------------------
  // A hardware device context is an AVBufferRef whose payload is an
  // AVHWDeviceContext; the codec context then owns a reference to it.
  late final Pointer<Void> Function(int deviceType) hwDeviceCtxAlloc;
  late final int Function(Pointer<Void> ref) hwDeviceCtxInit;
  late final Pointer<Void> Function(Pointer<Void> ref) bufferRef;
  late final void Function(Pointer<Pointer<Void>> ref) bufferUnref;

  /// Downloads a hardware frame into a software frame (AV_PIX_FMT_NV12).
  late final int Function(
    Pointer<Void> destination,
    Pointer<Void> source,
    int flags,
  ) hwFrameTransferData;

  static FfmpegLibraries open({String? libraryDirectory}) {
    final directory = libraryDirectory ?? findLibraryDirectory();
    if (directory == null) {
      throw const FfmpegException(
        'FFmpeg DLLs were not found. Run tool/fetch_ffmpeg.ps1 or set '
        'SCREENCAST_FFMPEG_DIR.',
      );
    }

    final utilName = _findLibrary(directory, 'avutil');
    final swresampleName = _findLibrary(directory, 'swresample');
    final codecName = _findLibrary(directory, 'avcodec');
    if (utilName == null || codecName == null) {
      throw FfmpegException(
        'avutil/avcodec DLLs were not found in $directory.',
      );
    }

    // Windows resolves dependent DLL imports by the module already in the
    // process. Load dependencies first so avcodec can bind to avutil and
    // swresample before it is opened.
    final avutil = DynamicLibrary.open(p.join(directory, utilName));
    final swresample = swresampleName == null
        ? avutil
        : DynamicLibrary.open(p.join(directory, swresampleName));
    final avcodec = DynamicLibrary.open(p.join(directory, codecName));

    return FfmpegLibraries._(
      avutil: avutil,
      swresample: swresample,
      avcodec: avcodec,
    );
  }

  /// Returns the first directory containing a usable avcodec/avutil pair.
  static String? findLibraryDirectory() {
    const compiled = String.fromEnvironment('SCREENCAST_FFMPEG_DIR');
    final candidates = <String>[
      if (compiled.isNotEmpty) compiled,
      if ((Platform.environment['SCREENCAST_FFMPEG_DIR'] ?? '').isNotEmpty)
        Platform.environment['SCREENCAST_FFMPEG_DIR']!,
      if ((Platform.environment['FFMPEG_DIR'] ?? '').isNotEmpty)
        Platform.environment['FFMPEG_DIR']!,
      p.join(Directory.current.path, 'third_party', 'ffmpeg', 'bin'),
      File(Platform.resolvedExecutable).parent.path,
      p.join(File(Platform.resolvedExecutable).parent.path, 'ffmpeg'),
      p.join(
        File(Platform.resolvedExecutable).parent.path,
        'data',
        'flutter_assets',
        'ffmpeg',
      ),
    ];

    for (final candidate in candidates) {
      if (candidate.isEmpty || !Directory(candidate).existsSync()) {
        continue;
      }
      if (_findLibrary(candidate, 'avcodec') != null &&
          _findLibrary(candidate, 'avutil') != null) {
        return p.normalize(candidate);
      }
    }
    return null;
  }

  void _bind() {
    avMallocz = _avutil.lookupFunction<Pointer<Uint8> Function(IntPtr),
        Pointer<Uint8> Function(int)>('av_mallocz');
    avFree = _avutil.lookupFunction<Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)>(
      'av_free',
    );

    findDecoder = _avcodec.lookupFunction<Pointer<Void> Function(Int32),
        Pointer<Void> Function(int)>('avcodec_find_decoder');
    allocContext = _avcodec.lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)>('avcodec_alloc_context3');
    openContext = _avcodec.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>(
      'avcodec_open2',
    );
    freeContext = _avcodec.lookupFunction<Void Function(Pointer<Pointer<Void>>),
        void Function(Pointer<Pointer<Void>>)>('avcodec_free_context');
    sendPacket = _avcodec.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)>('avcodec_send_packet');
    receiveFrame = _avcodec.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)>('avcodec_receive_frame');

    packetAlloc = _avcodec.lookupFunction<Pointer<Void> Function(),
        Pointer<Void> Function()>('av_packet_alloc');
    packetUnref = _avcodec.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('av_packet_unref');
    packetFree = _avcodec.lookupFunction<Void Function(Pointer<Pointer<Void>>),
        void Function(Pointer<Pointer<Void>>)>('av_packet_free');
    packetFromData = _avcodec.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32),
        int Function(Pointer<Void>, Pointer<Uint8>, int)>(
      'av_packet_from_data',
    );

    frameAlloc = _avutil.lookupFunction<Pointer<Void> Function(),
        Pointer<Void> Function()>('av_frame_alloc');
    frameUnref = _avutil.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('av_frame_unref');
    frameFree = _avutil.lookupFunction<Void Function(Pointer<Pointer<Void>>),
        void Function(Pointer<Pointer<Void>>)>('av_frame_free');

    hwDeviceCtxAlloc = _avutil.lookupFunction<Pointer<Void> Function(Int32),
            Pointer<Void> Function(int)>('av_hwdevice_ctx_alloc');
    hwDeviceCtxInit = _avutil.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('av_hwdevice_ctx_init');
    bufferRef = _avutil.lookupFunction<Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)>('av_buffer_ref');
    bufferUnref = _avutil.lookupFunction<Void Function(Pointer<Pointer<Void>>),
        void Function(Pointer<Pointer<Void>>)>('av_buffer_unref');
    hwFrameTransferData = _avutil.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Int32),
        int Function(Pointer<Void>, Pointer<Void>, int)>(
      'av_hwframe_transfer_data',
    );
  }
}

String? _findLibrary(String directory, String prefix) {
  final pattern = RegExp('^$prefix-\\d+\\.dll\$', caseSensitive: false);
  final files = Directory(directory).listSync().whereType<File>().map(
        (File file) => p.basename(file.path),
      );
  for (final name in files) {
    if (pattern.hasMatch(name)) {
      return name;
    }
  }
  return null;
}

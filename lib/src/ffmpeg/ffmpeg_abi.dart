/// FFmpeg 8.1.2 ABI facts needed by the D3D11VA path.
///
/// All values were produced by `tool/ffmpeg_abi_dump.c` compiled against the
/// exact headers of the bundled build (gyan.dev `ffmpeg-8.1.2-full_build-shared`,
/// libavcodec 62). `FfmpegDecoder` re-checks `AVCodecContext.codec_id` at
/// runtime and refuses to touch the struct when the layout does not match, so a
/// future FFmpeg bump degrades to software decoding instead of crashing.
///
/// Re-generate with:
///   `cl /nologo /W0 /I ffmpeg/include tool\ffmpeg_abi_dump.c`
///   `ffmpeg_abi_dump.exe`
class FfmpegAbi {
  FfmpegAbi._();

  /// `AVCodecContext` size of the bundled build.
  static const int codecContextSize = 864;

  // AVCodecContext field offsets.
  static const int offsetCodecType = 12;
  static const int offsetCodecId = 24;
  static const int offsetPixFmt = 136;
  static const int offsetGetFormat = 192;
  static const int offsetHwDeviceCtx = 560;

  /// `AVBufferRef.data` offset (the payload pointer of a `AVBufferRef*`).
  static const int offsetBufferData = 8;

  /// `AVHWDeviceContext.hwctx` offset.
  static const int offsetHwDeviceHwctx = 16;

  /// `AVD3D11VADeviceContext` size and the two fields used for sharing.
  static const int d3d11vaDeviceContextSize = 64;
  static const int offsetD3d11vaDevice = 0;
  static const int offsetD3d11vaDeviceContext = 8;

  // AVPixelFormat / AVHWDeviceType / AVCodecID values.
  static const int pixFmtYuv420p = 0;
  static const int pixFmtYuvj420p = 12;
  static const int pixFmtNv12 = 23;
  static const int pixFmtD3d11 = 171;
  static const int pixFmtNone = -1;
  static const int hwDeviceTypeD3d11va = 7;
  static const int codecIdH264 = 27;
}

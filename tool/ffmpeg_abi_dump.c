// Prints the FFmpeg 8.1.2 ABI facts the Dart FFI hardware-acceleration path
// needs. Build-time helper only: it is never shipped and never loaded at
// runtime. Re-run it whenever the bundled FFmpeg build changes and paste the
// values into lib/src/ffmpeg/ffmpeg_hwaccel.dart.
//
// Build (from a VS Build Tools prompt):
//   cl /nologo /I <ffmpeg>/include tool\ffmpeg_abi_dump.c /Fe:build\ffmpeg-abi.exe
//   build\ffmpeg-abi.exe

#include <stddef.h>
#include <stdio.h>

#include "libavcodec/avcodec.h"
#include "libavutil/frame.h"
#include "libavutil/hwcontext.h"
#include "libavutil/hwcontext_d3d11va.h"
#include "libavutil/pixfmt.h"

int main(void) {
    printf("ffmpeg_abi_version=%u\n", (unsigned)LIBAVCODEC_VERSION_MAJOR);
    printf("avcodec_context_size=%zu\n", sizeof(AVCodecContext));
    printf("avcodec_offset_codec_type=%zu\n", offsetof(AVCodecContext, codec_type));
    printf("avcodec_offset_codec_id=%zu\n", offsetof(AVCodecContext, codec_id));
    printf("avcodec_offset_width=%zu\n", offsetof(AVCodecContext, width));
    printf("avcodec_offset_height=%zu\n", offsetof(AVCodecContext, height));
    printf("avcodec_offset_pix_fmt=%zu\n", offsetof(AVCodecContext, pix_fmt));
    printf("avcodec_offset_get_format=%zu\n", offsetof(AVCodecContext, get_format));
    printf("avcodec_offset_hw_device_ctx=%zu\n", offsetof(AVCodecContext, hw_device_ctx));

    printf("avframe_size=%zu\n", sizeof(AVFrame));
    printf("avframe_offset_data=%zu\n", offsetof(AVFrame, data));
    printf("avframe_offset_linesize=%zu\n", offsetof(AVFrame, linesize));
    printf("avframe_offset_width=%zu\n", offsetof(AVFrame, width));
    printf("avframe_offset_height=%zu\n", offsetof(AVFrame, height));
    printf("avframe_offset_format=%zu\n", offsetof(AVFrame, format));
    printf("avframe_offset_hw_frames_ctx=%zu\n", offsetof(AVFrame, hw_frames_ctx));

    printf("avbuffer_ref_size=%zu\n", sizeof(AVBufferRef));
    printf("avbuffer_ref_offset_data=%zu\n", offsetof(AVBufferRef, data));
    printf("avhwdevice_context_size=%zu\n", sizeof(AVHWDeviceContext));
    printf("avhwdevice_context_offset_hwctx=%zu\n", offsetof(AVHWDeviceContext, hwctx));
    printf("avd3d11va_device_context_size=%zu\n", sizeof(AVD3D11VADeviceContext));
    printf("avd3d11va_offset_device=%zu\n", offsetof(AVD3D11VADeviceContext, device));
    printf("avd3d11va_offset_device_context=%zu\n",
           offsetof(AVD3D11VADeviceContext, device_context));
    printf("avd3d11va_offset_lock=%zu\n", offsetof(AVD3D11VADeviceContext, lock));
    printf("avd3d11va_offset_unlock=%zu\n", offsetof(AVD3D11VADeviceContext, unlock));
    printf("avd3d11va_offset_lock_ctx=%zu\n", offsetof(AVD3D11VADeviceContext, lock_ctx));

    printf("pix_fmt_yuv420p=%d\n", AV_PIX_FMT_YUV420P);
    printf("pix_fmt_yuvj420p=%d\n", AV_PIX_FMT_YUVJ420P);
    printf("pix_fmt_nv12=%d\n", AV_PIX_FMT_NV12);
    printf("pix_fmt_d3d11=%d\n", AV_PIX_FMT_D3D11);
    printf("pix_fmt_none=%d\n", AV_PIX_FMT_NONE);
    printf("hwdevice_type_d3d11va=%d\n", AV_HWDEVICE_TYPE_D3D11VA);
    printf("codec_id_h264=%d\n", AV_CODEC_ID_H264);
    printf("avg_frame_flag_hw=%d\n", 0);
    return 0;
}

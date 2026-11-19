package com.example.screencast.server;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Surface;

import java.io.IOException;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.util.List;

/**
 * Captures the default display into a MediaCodec input Surface and emits one
 * SCRC packet per encoded H.264 NAL.
 *
 * <p>The encoder is configured in Surface input mode. This class never calls
 * dequeueInputBuffer()/queueInputBuffer(): the virtual display is the producer
 * for MediaCodec.createInputSurface().
 *
 * <p>Display creation first tries the hidden DisplayManager system API, then
 * falls back to SurfaceControl. A failure is fatal and explicit; there is no
 * MediaProjection path.
 */
public final class VirtualDisplayCaptureBackend implements CaptureBackend {
    private static final String VIDEO_MIME = MediaFormat.MIMETYPE_VIDEO_AVC;
    private static final long DEQUEUE_TIMEOUT_US = 10_000;

    /** How long the frame-rate hint gets before it is measured. */
    private static final long TARGET_FPS_MEASURE_DELAY_MS = 5_000L;
    private static final int TARGET_FPS_TOLERANCE = 2;

    private final ServerOptions options;

    /**
     * Shared with the control server: recomputed here for every virtual display
     * so input injection follows the source aspect ratio after rotation.
     */
    private final InputMapping inputMapping;

    private volatile boolean closed;
    private boolean started;
    private MediaCodec codec;
    private Surface inputSurface;
    private VirtualDisplayFactory.Handle display;

    private byte[] sps;
    private byte[] pps;
    private long idrCount;
    private boolean warnedMissingParameterSets;

    /** SCRC payload bytes (NAL sizes, SCRC header excluded) since the last log. */
    private long payloadBytesSinceBitrateLog;
    private long bitrateWindowStartMs;
    private long framesSinceBitrateLog;

    /** When Surface.setFrameRate was called (0 = never requested). */
    private long targetFpsHintAppliedAtMs;
    private boolean targetFpsReported;

    public VirtualDisplayCaptureBackend(ServerOptions options, InputMapping inputMapping) {
        this.options = options;
        this.inputMapping = inputMapping;
    }

    @Override
    public void run(NalUnitSink sink) throws Exception {
        if (started) {
            throw new IllegalStateException("Capture backend can only be started once");
        }
        started = true;
        closed = false;

        // Some vendor display/codec stacks require a Looper on the thread that
        // creates the virtual display and drives the encoder. app_process's
        // main thread does not necessarily have one.
        if (Looper.myLooper() == null) {
            Looper.prepare();
        }

        CaptureLog.info(
            "Android API " + Build.VERSION.SDK_INT
                + ", encoder target " + options.width() + "x" + options.height()
                + " @" + options.frameRate() + "fps, "
                + options.bitRate() + "bps, keyframe every "
                + options.iFrameIntervalSeconds() + "s"
        );
        logEncoderCapabilities();

        try {
            codec = createEncoderWithLowLatencyFallback();
            inputSurface = codec.createInputSurface();
            CaptureLog.info("MediaCodec surface input created");

            display = VirtualDisplayFactory.create(options, inputSurface);
            CaptureLog.info("Virtual display ready: " + display.backendName());

            // The letterbox depends on the mirrored display, not on the encoder
            // size: recompute it now that the display exists. Reading the size
            // after creation keeps rotation and resolution changes in sync with
            // the frames the viewer is about to receive.
            refreshInputMapping();

            // Optional "limit 60 fps" hint. Applied after the display exists so
            // SurfaceFlinger can bind it to the virtual display's frame rate.
            applyTargetFrameRateHint();

            codec.start();
            CaptureLog.info("MediaCodec encoder started: " + codec.getName());
            bitrateWindowStartMs = SystemClock.uptimeMillis();

            encodeLoop(sink);
        } catch (java.net.SocketException disconnected) {
            CaptureLog.info(
                "Viewer disconnected; closing capture: " + disconnected.getMessage()
            );
            throw disconnected;
        } catch (Exception error) {
            CaptureLog.error("Capture/encode pipeline failed", error);
            throw error;
        } finally {
            close();
        }
    }

    /**
     * Recomputes the input letterbox from the encoder size and the real source
     * display size.
     *
     * <p>Called once per created virtual display, so a rotated phone produces a
     * different content box on the next viewer session instead of reusing the
     * previous aspect ratio. The mapping is logged before any injection can use
     * it, matching the "print video size, content size and margins" contract.
     */
    private void refreshInputMapping() {
        final int[] source = DisplayMetadata.realSize(options);
        final int sourceWidth = source[0] > 0 ? source[0] : options.width();
        final int sourceHeight = source[1] > 0 ? source[1] : options.height();
        final boolean changed = inputMapping.update(
            options.width(),
            options.height(),
            sourceWidth,
            sourceHeight
        );
        final LetterboxGeometry box = inputMapping.geometry();
        CaptureLog.info(
            "Input letterbox " + (changed ? "updated" : "unchanged") + ": "
                + box.describe()
                + " source=" + sourceWidth + "x" + sourceHeight
                + (box.hasPadding() ? " (bars present)" : " (no bars)")
        );
    }

    private MediaCodec createEncoderWithLowLatencyFallback() throws Exception {
        final boolean requestLowLatency = Build.VERSION.SDK_INT >= 30;
        try {
            return configureEncoder(requestLowLatency);
        } catch (Exception firstFailure) {
            if (!requestLowLatency) {
                throw firstFailure;
            }
            CaptureLog.error(
                "Encoder configure failed with KEY_LOW_LATENCY; retrying without it",
                firstFailure
            );
            try {
                return configureEncoder(false);
            } catch (Exception secondFailure) {
                secondFailure.addSuppressed(firstFailure);
                throw secondFailure;
            }
        }
    }

    private MediaCodec configureEncoder(boolean lowLatency) throws IOException {
        final MediaFormat format = createFormat(lowLatency);
        final MediaCodec encoder = MediaCodec.createEncoderByType(VIDEO_MIME);
        try {
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        } catch (Exception error) {
            encoder.release();
            throw error;
        }
        CaptureLog.info(
            "Encoder configured: " + encoder.getName()
                + (lowLatency ? " (KEY_LOW_LATENCY=1)" : " (no low-latency flag)")
        );
        // Report what the codec actually accepted, not only what was requested.
        try {
            logEncoderFormat("configured(input)", encoder.getInputFormat());
        } catch (Exception error) {
            CaptureLog.warn(
                "Could not read the configured encoder format: " + error.getMessage()
            );
        }
        return encoder;
    }

    private MediaFormat createFormat(boolean lowLatency) {
        final MediaFormat format = MediaFormat.createVideoFormat(
            VIDEO_MIME,
            options.width(),
            options.height()
        );
        format.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
        );
        format.setInteger(MediaFormat.KEY_BIT_RATE, options.bitRate());
        format.setInteger(MediaFormat.KEY_FRAME_RATE, options.frameRate());
        format.setInteger(
            MediaFormat.KEY_I_FRAME_INTERVAL,
            options.iFrameIntervalSeconds()
        );

        if (Build.VERSION.SDK_INT >= 23) {
            // Run the encoder thread at real-time priority.
            format.setInteger(MediaFormat.KEY_PRIORITY, 0);
        }
        if (Build.VERSION.SDK_INT >= 26) {
            // Output a frame as soon as one is queued.
            format.setInteger(MediaFormat.KEY_LATENCY, 1);
        }
        // Keep the SCRC decoder fed when the screen is static.
        format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000L);

        if (lowLatency && Build.VERSION.SDK_INT >= 30) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
        }
        return format;
    }

    private void encodeLoop(NalUnitSink sink) throws Exception {
        final MediaCodec.BufferInfo bufferInfo = new MediaCodec.BufferInfo();
        long frameCount = 0;
        long lastLogAt = 0;

        while (!closed) {
            final int outputBufferIndex;
            try {
                outputBufferIndex = codec.dequeueOutputBuffer(
                    bufferInfo,
                    DEQUEUE_TIMEOUT_US
                );
            } catch (IllegalStateException error) {
                if (closed) {
                    break;
                }
                throw error;
            }

            if (outputBufferIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                continue;
            }
            if (outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                final MediaFormat outputFormat = codec.getOutputFormat();
                CaptureLog.info("Encoder output format changed: " + outputFormat);
                // The output format is what the encoder actually applies; log
                // the three keys the baseline cares about explicitly.
                logEncoderFormat("effective(output)", outputFormat);
                continue;
            }
            if (outputBufferIndex < 0) {
                CaptureLog.warn("Unexpected MediaCodec output index: " + outputBufferIndex);
                continue;
            }

            try {
                if (bufferInfo.size > 0) {
                    final ByteBuffer output = codec.getOutputBuffer(outputBufferIndex);
                    if (output != null) {
                        output.position(bufferInfo.offset);
                        output.limit(bufferInfo.offset + bufferInfo.size);
                        final byte[] encoded = new byte[bufferInfo.size];
                        output.get(encoded);

                        final int vclCount = writeAccessUnit(encoded, sink);
                        if (vclCount > 0
                            && (bufferInfo.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                            frameCount += vclCount;
                            framesSinceBitrateLog += vclCount;
                            if (frameCount == 1) {
                                CaptureLog.info(
                                    "First encoded frame received ("
                                        + options.width() + "x" + options.height() + ")"
                                );
                            } else if (frameCount - lastLogAt >= 120) {
                                lastLogAt = frameCount;
                                CaptureLog.info("Encoded frames: " + frameCount);
                            }
                        }
                    }
                }
            } finally {
                codec.releaseOutputBuffer(outputBufferIndex, false);
            }

            logBitrateIfDue();

            if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                CaptureLog.info("Encoder reached end of stream");
                break;
            }
        }

        CaptureLog.info("Capture loop ended after " + frameCount + " encoded frames");
    }

    /**
     * EXPERIMENT B (temporary, reverted after measurement): logs which bitrate
     * modes the AVC encoders on this device report.
     */
    private void logEncoderCapabilities() {
        try {
            final MediaCodecList codecList =
                new MediaCodecList(MediaCodecList.REGULAR_CODECS);
            for (MediaCodecInfo info : codecList.getCodecInfos()) {
                if (!info.isEncoder()) {
                    continue;
                }
                boolean supportsAvc = false;
                for (String type : info.getSupportedTypes()) {
                    if (VIDEO_MIME.equalsIgnoreCase(type)) {
                        supportsAvc = true;
                        break;
                    }
                }
                if (!supportsAvc) {
                    continue;
                }
                final MediaCodecInfo.CodecCapabilities capabilities =
                    info.getCapabilitiesForType(VIDEO_MIME);
                final MediaCodecInfo.EncoderCapabilities encoder =
                    capabilities.getEncoderCapabilities();
                CaptureLog.info(
                    "[encoder] " + info.getName() + " bitrateModes: CBR="
                        + encoder.isBitrateModeSupported(
                            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
                        )
                        + " VBR="
                        + encoder.isBitrateModeSupported(
                            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
                        )
                        + " CQ="
                        + encoder.isBitrateModeSupported(
                            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CQ
                        )
                );
            }
        } catch (Throwable error) {
            CaptureLog.warn(
                "[encoder] capability probe failed: " + error.getMessage()
            );
        }
    }

    /**
     * Prints the SCRC payload rate once per second: the total NAL payload bytes
     * written to the output stream (SCRC framing excluded) and the frames those
     * bytes belong to.
     */
    private void logBitrateIfDue() {
        final long now = SystemClock.uptimeMillis();
        final long elapsedMs = now - bitrateWindowStartMs;
        if (elapsedMs < 1000L) {
            return;
        }
        final long framesInWindow = framesSinceBitrateLog;
        final long kbps = (payloadBytesSinceBitrateLog * 8L) / elapsedMs;
        CaptureLog.info(
            "[encoder] 1s bitrate=" + kbps + " kbps bytes="
                + payloadBytesSinceBitrateLog + " frames="
                + framesInWindow + " window=" + elapsedMs + "ms"
        );
        reportTargetFpsIfDue(framesInWindow);
        payloadBytesSinceBitrateLog = 0L;
        framesSinceBitrateLog = 0L;
        bitrateWindowStartMs = now;
    }

    /**
     * Asks SurfaceFlinger for the requested capture rate (Android 11+).
     *
     * <p>This is only a hint: a ROM may ignore it, and this class never drops
     * frames to enforce it (dropping a P frame breaks the H.264 reference chain
     * and shows up as corruption). {@link #reportTargetFpsIfDue} reports what
     * actually happened 5 s later.
     */
    private void applyTargetFrameRateHint() {
        final int target = options.targetFps();
        if (target <= 0) {
            return;
        }
        targetFpsHintAppliedAtMs = SystemClock.uptimeMillis();
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            CaptureLog.warn(
                "[encoder] target-fps=" + target + " hint unavailable on API "
                    + Build.VERSION.SDK_INT + " (needs Android 11+)"
            );
            return;
        }
        if (inputSurface == null) {
            CaptureLog.warn(
                "[encoder] target-fps=" + target
                    + " hint skipped: no encoder input surface"
            );
            return;
        }
        try {
            final Method setFrameRate = Surface.class.getMethod(
                "setFrameRate", float.class, int.class, int.class
            );
            // Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE == 1
            // Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS == 0
            setFrameRate.invoke(inputSurface, (float) target, 1, 0);
            CaptureLog.info(
                "[encoder] target-fps=" + target
                    + " hint applied via Surface.setFrameRate"
            );
        } catch (Throwable error) {
            CaptureLog.warn(
                "[encoder] target-fps=" + target + " hint failed: " + error
            );
        }
    }

    /**
     * Logs whether the frame-rate hint actually changed the encoder output.
     *
     * <p>Measured once, five seconds after the hint, against the last one
     * second window. A ROM that ignores the hint keeps producing at the panel
     * rate; the UI shows that verbatim instead of pretending the limit worked.
     */
    private void reportTargetFpsIfDue(long framesInWindow) {
        final int target = options.targetFps();
        if (target <= 0 || targetFpsReported || targetFpsHintAppliedAtMs <= 0) {
            return;
        }
        if (SystemClock.uptimeMillis() - targetFpsHintAppliedAtMs
            < TARGET_FPS_MEASURE_DELAY_MS) {
            return;
        }
        targetFpsReported = true;
        final int actual = (int) framesInWindow;
        final boolean applied = Math.abs(actual - target) <= TARGET_FPS_TOLERANCE;
        CaptureLog.info(
            "[encoder] target-fps=" + target + " actual=" + actual
                + (applied ? " (hint applied)" : " (hint ignored by ROM)")
        );
    }

    /**
     * Logs the three encoder keys the wireless baseline reports on.
     *
     * <p>Called with the configured input format and again with the effective
     * output format, so a vendor encoder that silently adjusts bitrate or frame
     * rate is visible in the server log.
     */
    private static void logEncoderFormat(String stage, MediaFormat format) {
        CaptureLog.info(
            "[encoder] " + stage + " KEY_BIT_RATE="
                + formatInt(format, MediaFormat.KEY_BIT_RATE)
                + " KEY_I_FRAME_INTERVAL="
                + formatInt(format, MediaFormat.KEY_I_FRAME_INTERVAL)
                + " KEY_FRAME_RATE="
                + formatInt(format, MediaFormat.KEY_FRAME_RATE)
        );
    }

    private static int formatInt(MediaFormat format, String key) {
        try {
            if (format != null && format.containsKey(key)) {
                return format.getInteger(key);
            }
        } catch (Exception ignored) {
            // A missing or non-integer key is reported as -1.
        }
        return -1;
    }

    /**
     * Writes one NAL to the SCRC stream and accounts for its payload bytes.
     */
    private void writePayload(NalUnitSink sink, byte[] nal) throws IOException {
        payloadBytesSinceBitrateLog += nal.length;
        sink.writeNalUnit(nal);
    }

    /**
     * Writes all NALs in one MediaCodec output buffer, making sure the cached
     * SPS/PPS precede an IDR if the encoder did not include them in this buffer.
     *
     * @return number of VCL NALs seen (0 for a config-only buffer)
     */
    private int writeAccessUnit(byte[] encoded, NalUnitSink sink) throws IOException {
        final List<byte[]> nals = AvcNalSplitter.split(encoded);
        if (nals.isEmpty()) {
            CaptureLog.warn("MediaCodec returned an output buffer with no NAL units");
            return 0;
        }

        boolean hasSps = false;
        boolean hasPps = false;
        boolean hasIdr = false;
        int vclCount = 0;
        for (byte[] nal : nals) {
            final int type = nal[0] & 0x1f;
            if (type == 7) {
                hasSps = true;
            } else if (type == 8) {
                hasPps = true;
            } else if (type == 5) {
                hasIdr = true;
                vclCount++;
            } else if (type == 1) {
                vclCount++;
            }
        }

        if (hasIdr) {
            if (!hasSps || !hasPps) {
                // Re-send both cached parameter sets in SPS->PPS order rather
                // than interleaving a cached PPS before an in-buffer SPS.
                if (sps != null) {
                    writePayload(sink, sps);
                }
                if (pps != null) {
                    writePayload(sink, pps);
                }
                if ((!hasSps && sps == null) || (!hasPps && pps == null)) {
                    if (!warnedMissingParameterSets) {
                        warnedMissingParameterSets = true;
                        CaptureLog.warn(
                            "IDR produced before SPS/PPS were observed; decoder may reject the stream"
                        );
                    }
                }
            }
            idrCount++;
        }

        for (byte[] nal : nals) {
            final int type = nal[0] & 0x1f;
            if (type == 7) {
                sps = nal;
            } else if (type == 8) {
                pps = nal;
            }
            writePayload(sink, nal);
        }

        if (hasIdr) {
            CaptureLog.info("Sent IDR #" + idrCount + " with SPS/PPS parameter sets");
        }
        return vclCount;
    }

    @Override
    public void close() {
        if (closed && display == null && codec == null && inputSurface == null) {
            return;
        }
        closed = true;

        // Stop the producer before tearing down the codec input surface.
        final VirtualDisplayFactory.Handle currentDisplay = display;
        display = null;
        if (currentDisplay != null) {
            currentDisplay.close();
        }

        final MediaCodec currentCodec = codec;
        codec = null;
        if (currentCodec != null) {
            try {
                currentCodec.stop();
            } catch (Exception error) {
                CaptureLog.warn(
                    "MediaCodec.stop() during cleanup failed: " + error.getMessage()
                );
            }
            try {
                currentCodec.release();
            } catch (Exception error) {
                CaptureLog.warn(
                    "MediaCodec.release() during cleanup failed: " + error.getMessage()
                );
            }
        }

        final Surface currentSurface = inputSurface;
        inputSurface = null;
        if (currentSurface != null) {
            try {
                currentSurface.release();
            } catch (Exception error) {
                CaptureLog.warn(
                    "Input Surface.release() during cleanup failed: " + error.getMessage()
                );
            }
        }
    }
}

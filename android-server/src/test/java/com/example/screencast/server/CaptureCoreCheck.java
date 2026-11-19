package com.example.screencast.server;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;
import java.util.List;

/**
 * JVM-only checks for the Android-independent capture helpers.
 *
 * <p>Run after tool/build_server.ps1:
 * javac -cp build/server/classes -d build/server/test-classes
 *   android-server/src/test/java/com/example/screencast/server/CaptureCoreCheck.java
 * java -cp build/server/classes;build/server/test-classes
 *   com.example.screencast.server.CaptureCoreCheck
 */
public final class CaptureCoreCheck {
    public static void main(String[] args) {
        checkAnnexB();
        checkFourByteStartCodes();
        checkLengthPrefixed();
        checkControlProtocol();
        checkOptions();
        checkLetterboxWideDisplay();
        checkLetterboxPortraitDisplay();
        checkLetterboxIdentity();
        checkLetterboxPillarbox();
        checkLetterboxSquare();
        checkLetterboxMapping();
        checkDisplayOrientation();
        checkInputMappingUpdates();
        checkRotationRemap();
        checkWheelMapping();
        System.out.println("CaptureCoreCheck passed.");
    }

    private static void checkAnnexB() {
        byte[] buffer = concat(
            new byte[]{0, 0, 0, 1, 0x67, 0x42, 0x01, 0x02},
            new byte[]{0, 0, 1, 0x68, 0x44, 0x02},
            new byte[]{0, 0, 1, 0x65, 0x11, 0x22, 0x33}
        );
        List<byte[]> nals = AvcNalSplitter.split(buffer);
        require(nals.size() == 3, "expected 3 Annex-B NALs, got " + nals.size());
        require(Arrays.equals(nals.get(0), new byte[]{0x67, 0x42, 0x01, 0x02}), "SPS mismatch");
        require(Arrays.equals(nals.get(1), new byte[]{0x68, 0x44, 0x02}), "PPS mismatch");
        require(
            Arrays.equals(nals.get(2), new byte[]{0x65, 0x11, 0x22, 0x33}),
            "IDR mismatch or truncated"
        );
    }

    private static void checkFourByteStartCodes() {
        byte[] buffer = new byte[]{
            0, 0, 0, 1, 0x67, 0x10,
            0, 0, 0, 1, 0x68, 0x20,
            0, 0, 0, 1, 0x65, 0x30, 0x40
        };
        List<byte[]> nals = AvcNalSplitter.split(buffer);
        require(nals.size() == 3, "expected 3 four-byte-start NALs");
        require(Arrays.equals(nals.get(2), new byte[]{0x65, 0x30, 0x40}), "last NAL truncated");
    }

    private static void checkLengthPrefixed() {
        ByteArrayOutputStream stream = new ByteArrayOutputStream();
        appendLengthPrefixed(stream, new byte[]{0x67, 0x01, 0x02});
        appendLengthPrefixed(stream, new byte[]{0x68, 0x03});
        List<byte[]> nals = AvcNalSplitter.split(stream.toByteArray());
        require(nals.size() == 2, "expected 2 length-prefixed NALs");
        require(Arrays.equals(nals.get(1), new byte[]{0x68, 0x03}), "AVCC NAL mismatch");
    }

    private static void checkControlProtocol() {
        require(
            ControlProtocol.TYPE_SHUTDOWN == 0x10,
            "shutdown opcode must stay 0x10"
        );
        require(
            ControlProtocol.SHUTDOWN_PAYLOAD_BYTES == 0,
            "shutdown payload must be empty"
        );
        // The app-stop path relies on these staying backwards compatible.
        require(
            ControlProtocol.TYPE_TOUCH_DOWN == 0x01
                && ControlProtocol.TYPE_WHEEL == 0x04
                && ControlProtocol.TYPE_KEY_UP == 0x06,
            "existing input opcodes must stay unchanged"
        );
    }

    private static void checkOptions() {        ServerOptions options = ServerOptions.parse(
            new String[]{
                "--port=28000",
                "--width=1920",
                "--height=1080",
                "--bit-rate=12000000",
                "--frame-rate=30",
            }
        );
        require(options.port() == 28000, "port parse failed");
        require(options.width() == 1920 && options.height() == 1080, "size parse failed");
        require(options.bitRate() == 12_000_000, "bitrate parse failed");
        require(options.frameRate() == 30, "fps parse failed");
        require(
            "127.0.0.1".equals(options.bindAddress()),
            "default bind address failed"
        );

        ServerOptions wireless = ServerOptions.parse(
            new String[]{"--bind-address=0.0.0.0", "--port=28001"}
        );
        require(
            "0.0.0.0".equals(wireless.bindAddress()),
            "bind address parse failed"
        );
        require(wireless.port() == 28001, "wireless port parse failed");

        requireThrows(
            () -> ServerOptions.parse(new String[]{"--bind-address="}),
            "empty bind address must be rejected"
        );

        ServerOptions forced = ServerOptions.parse(
            new String[]{"--display-backend=surfacecontrol"}
        );
        require(
            "surfacecontrol".equals(forced.displayBackend()),
            "display backend parse failed"
        );

        // --target-fps: 0 (default) = no hint, positive = Surface.setFrameRate.
        require(
            ServerOptions.parse(new String[]{}).targetFps() == 0,
            "target-fps must default to 0 (unlimited)"
        );
        ServerOptions limited = ServerOptions.parse(
            new String[]{"--target-fps=60"}
        );
        require(limited.targetFps() == 60, "target-fps parse failed");
        require(
            ServerOptions.parse(new String[]{"--target-fps=0"}).targetFps() == 0,
            "target-fps=0 must stay unlimited"
        );
        requireThrows(
            () -> ServerOptions.parse(new String[]{"--target-fps=-1"}),
            "negative target-fps must be rejected"
        );
        requireThrows(
            () -> ServerOptions.parse(new String[]{"--target-fps="}),
            "empty target-fps must be rejected"
        );
        requireThrows(
            () -> ServerOptions.parse(new String[]{"--target-fps=241"}),
            "target-fps above the maximum must be rejected"
        );
    }

    /**
     * The geometry the implementation used to hard-code for the OPPO Android 14
     * device: a 4:3-ish 2800x2000 source inside a 1280x720 encoder frame leaves
     * 1008x720 content and 136 px side bars.
     */
    private static void checkLetterboxWideDisplay() {
        LetterboxGeometry box = LetterboxGeometry.fit(1280, 720, 2800, 2000);
        require(box.contentWidth() == 1008, "wide display content width: " + box);
        require(box.contentHeight() == 720, "wide display content height: " + box);
        require(box.offsetX() == 136, "wide display offsetX: " + box);
        require(box.offsetY() == 0, "wide display offsetY: " + box);
        require(box.hasPadding(), "wide display must report bars");
    }

    /** Portrait panel: the video is pillarboxed with wide side bars. */
    private static void checkLetterboxPortraitDisplay() {
        LetterboxGeometry box = LetterboxGeometry.fit(1280, 720, 1080, 2400);
        require(box.contentWidth() == 324, "portrait content width: " + box);
        require(box.contentHeight() == 720, "portrait content height: " + box);
        require(box.offsetX() == 478, "portrait offsetX: " + box);
        require(box.offsetY() == 0, "portrait offsetY: " + box);
    }

    /** Matching aspect ratios must produce no padding at all. */
    private static void checkLetterboxIdentity() {
        LetterboxGeometry box = LetterboxGeometry.identity(1920, 1080);
        require(box.contentWidth() == 1920, "identity content width: " + box);
        require(box.contentHeight() == 1080, "identity content height: " + box);
        require(box.offsetX() == 0 && box.offsetY() == 0, "identity padding: " + box);
        require(!box.hasPadding(), "identity must not report bars");

        // 1920x1080 video for the same 16:9 display is also bar-free.
        LetterboxGeometry sameAspect = LetterboxGeometry.fit(1920, 1080, 1600, 900);
        require(sameAspect.offsetX() == 0, "same aspect offsetX: " + sameAspect);
        require(sameAspect.offsetY() == 0, "same aspect offsetY: " + sameAspect);
        require(
            sameAspect.contentWidth() == 1920 && sameAspect.contentHeight() == 1080,
            "same aspect content: " + sameAspect
        );
    }

    /** Portrait video inside a landscape display gets top/bottom bars. */
    private static void checkLetterboxPillarbox() {
        LetterboxGeometry box = LetterboxGeometry.fit(720, 1280, 2800, 2000);
        require(box.contentWidth() == 720, "pillarbox content width: " + box);
        require(box.contentHeight() == 514, "pillarbox content height: " + box);
        require(box.offsetX() == 0, "pillarbox offsetX: " + box);
        require(box.offsetY() == 383, "pillarbox offsetY: " + box);
    }

    /** Square video inside a tall display is letterboxed on the sides only. */
    private static void checkLetterboxSquare() {
        LetterboxGeometry box = LetterboxGeometry.fit(720, 720, 1600, 2560);
        require(box.contentWidth() == 450, "square content width: " + box);
        require(box.contentHeight() == 720, "square content height: " + box);
        require(box.offsetX() == 135, "square offsetX: " + box);
        require(box.offsetY() == 0, "square offsetY: " + box);
    }

    /** Normalized coordinates must be mapped through the content box. */
    private static void checkLetterboxMapping() {
        LetterboxGeometry box = LetterboxGeometry.fit(1280, 720, 2800, 2000);

        require(box.displayXFor(0.0) == 0, "left edge x: " + box.displayXFor(0.0));
        require(box.displayYFor(0.0) == 0, "top edge y: " + box.displayYFor(0.0));
        require(
            box.displayXFor(1.0) == 2799,
            "right edge x: " + box.displayXFor(1.0)
        );
        require(
            box.displayYFor(1.0) == 1999,
            "bottom edge y: " + box.displayYFor(1.0)
        );
        require(
            box.displayXFor(0.5) == 1400,
            "center x: " + box.displayXFor(0.5)
        );
        require(
            box.displayYFor(0.5) == 1000,
            "center y: " + box.displayYFor(0.5)
        );

        // A pointer on the left bar clamps to the display edge instead of
        // injecting a negative coordinate.
        require(
            box.displayXForVideo(0) == 0,
            "bar pointer must clamp to 0, got " + box.displayXForVideo(0)
        );
        require(
            box.displayXForVideo(1008 + 136) == 2799,
            "content right edge must clamp to 2799, got "
                + box.displayXForVideo(1008 + 136)
        );

        // Identity geometry maps 1:1 in the 0..length-1 range.
        LetterboxGeometry plain = LetterboxGeometry.identity(1000, 500);
        require(plain.displayXFor(0.25) == 250, "plain x: " + plain.displayXFor(0.25));
        require(plain.displayYFor(1.0) == 499, "plain y: " + plain.displayYFor(1.0));
    }

    /**
     * Display.getRealSize() reports the panel in its natural orientation, while
     * the mirrored content follows the logical orientation. The orientation
     * alignment must keep the verified reference mapping intact.
     */
    private static void checkDisplayOrientation() {
        // Reference device: portrait panel 2000x2800 mirrored as a landscape
        // 2800x2000 logical display. Orienting the real size must produce the
        // 2800x2000 that yields the verified 1008x720 / 136 letterbox.
        int[] oriented = LetterboxGeometry.orient(2000, 2800, 2800, 2000);
        require(oriented[0] == 2800 && oriented[1] == 2000, "landscape orientation");
        LetterboxGeometry reference = LetterboxGeometry.fit(1280, 720, oriented[0], oriented[1]);
        require(reference.contentWidth() == 1008, "reference content width: " + reference);
        require(reference.offsetX() == 136, "reference offsetX: " + reference);

        // Already matching orientation is untouched.
        int[] sameOrientation = LetterboxGeometry.orient(2800, 2000, 2800, 2000);
        require(
            sameOrientation[0] == 2800 && sameOrientation[1] == 2000,
            "same orientation must not swap"
        );
        int[] portraitPanel = LetterboxGeometry.orient(2800, 2000, 2000, 2800);
        require(
            portraitPanel[0] == 2000 && portraitPanel[1] == 2800,
            "portrait logical orientation must swap"
        );

        // Square panels and missing logical sizes are left alone.
        int[] square = LetterboxGeometry.orient(1000, 1000, 2800, 2000);
        require(square[0] == 1000 && square[1] == 1000, "square must not swap");
        int[] unknown = LetterboxGeometry.orient(2000, 2800, 0, 0);
        require(unknown[0] == 2000 && unknown[1] == 2800, "unknown reference must not swap");
    }

    /** The capture backend swaps the geometry; identical sizes report no change. */
    private static void checkInputMappingUpdates() {
        InputMapping mapping = new InputMapping(1280, 720, 2800, 2000);
        require(
            mapping.geometry().contentWidth() == 1008,
            "initial mapping: " + mapping.geometry()
        );

        require(
            !mapping.update(1280, 720, 2800, 2000),
            "identical sizes must not report a change"
        );

        // Rotated phone: the display becomes 2000x2800.
        require(
            mapping.update(1280, 720, 2000, 2800),
            "rotation must report a change"
        );
        LetterboxGeometry rotated = mapping.geometry();
        require(rotated.contentWidth() == 514, "rotated content width: " + rotated);
        require(rotated.contentHeight() == 720, "rotated content height: " + rotated);
        require(rotated.offsetX() == 383, "rotated offsetX: " + rotated);
        require(rotated.offsetY() == 0, "rotated offsetY: " + rotated);
        require(
            mapping.geometry().displayXFor(0.5) == 1000,
            "rotated center x: " + mapping.geometry().displayXFor(0.5)
        );
    }

    /**
     * Mid-session rotation: the injector polls Display.getRealSize()/rotation,
     * and a changed DisplayState must produce a new content box from the same
     * InputMapping (no reconnect involved).
     */
    private static void checkRotationRemap() {
        DisplayMetadata.DisplayState landscape =
            new DisplayMetadata.DisplayState(2800, 2000, 0);
        DisplayMetadata.DisplayState portrait =
            new DisplayMetadata.DisplayState(2000, 2800, 1);

        require(landscape.sameAs(landscape), "identical state must match");
        require(!landscape.sameAs(portrait), "rotation must differ");
        require(!landscape.sameAs(null), "null state must not match");

        InputMapping mapping = new InputMapping(
            1280,
            720,
            landscape.width,
            landscape.height
        );
        require(
            mapping.geometry().contentWidth() == 1008,
            "landscape content width: " + mapping.geometry()
        );
        require(
            mapping.videoWidth() == 1280 && mapping.videoHeight() == 720,
            "video size must survive the remap"
        );

        // The injector calls exactly this when the polled state changes.
        final boolean changed = mapping.update(
            mapping.videoWidth(),
            mapping.videoHeight(),
            portrait.width,
            portrait.height
        );
        require(changed, "rotation must report a mapping change");
        LetterboxGeometry rotated = mapping.geometry();
        require(rotated.contentWidth() == 514, "rotated content width: " + rotated);
        require(rotated.contentHeight() == 720, "rotated content height: " + rotated);
        require(rotated.offsetX() == 383, "rotated offsetX: " + rotated);
        require(rotated.offsetY() == 0, "rotated offsetY: " + rotated);

        // A pointer that was centered in the old orientation maps to the new
        // display center instead of a stale coordinate.
        require(
            rotated.displayXFor(0.5) == 1000 && rotated.displayYFor(0.5) == 1400,
            "rotated center: " + rotated.displayXFor(0.5) + ","
                + rotated.displayYFor(0.5)
        );
    }

    /**
     * Windows delta -> Android AXIS_VSCROLL. Measured on the OPPO Android 14
     * device: the signs agree, so the value passes through unchanged (+120
     * scrolls the list up). The earlier negated mapping scrolled backwards.
     */
    private static void checkWheelMapping() {
        require(
            WheelMapping.axisVScrollForWindowsDelta(120) == 120,
            "forward notch must stay +120"
        );
        require(
            WheelMapping.axisVScrollForWindowsDelta(-120) == -120,
            "backward notch must stay -120"
        );
        require(
            WheelMapping.axisVScrollForWindowsDelta(240) == 240,
            "two forward notches must stay +240"
        );
        require(
            WheelMapping.axisVScrollForWindowsDelta(0) == 0,
            "zero delta must stay zero"
        );
        // Precision is preserved rather than rounded to whole notches.
        require(
            WheelMapping.axisVScrollForWindowsDelta(-40) == -40,
            "partial notch must keep its magnitude"
        );
        require(WheelMapping.WHEEL_DELTA == 120, "WHEEL_DELTA mismatch");
    }

    private static void appendLengthPrefixed(ByteArrayOutputStream stream, byte[] nal) {
        stream.write((nal.length >>> 24) & 0xff);
        stream.write((nal.length >>> 16) & 0xff);
        stream.write((nal.length >>> 8) & 0xff);
        stream.write(nal.length & 0xff);
        stream.write(nal, 0, nal.length);
    }

    private static byte[] concat(byte[]... arrays) {
        int size = 0;
        for (byte[] array : arrays) {
            size += array.length;
        }
        byte[] result = new byte[size];
        int offset = 0;
        for (byte[] array : arrays) {
            System.arraycopy(array, 0, result, offset, array.length);
            offset += array.length;
        }
        return result;
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static void requireThrows(Runnable action, String message) {
        try {
            action.run();
        } catch (IllegalArgumentException expected) {
            return;
        }
        throw new AssertionError(message);
    }

    private CaptureCoreCheck() {
    }
}

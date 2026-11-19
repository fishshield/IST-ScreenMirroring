package com.example.screencast.server;

/**
 * How the mirrored source display fits inside the encoded video frame.
 *
 * <p>The virtual display letterboxes the source display into the encoder size
 * without changing the aspect ratio: the usable content area is the source
 * scaled by {@code min(video/display)} on both axes, and the leftover bars are
 * centered padding. Normalized touch coordinates address the video frame, so
 * this padding has to be removed before scaling back to display pixels.
 *
 * <p>The numbers were previously hard-coded for one device (1280x720 video,
 * 2800x2000 display, 1008x720 content, 136 px side bars). This class computes
 * them from the real sizes the server observes when it creates the virtual
 * display, so rotation and other display geometries map correctly.
 *
 * <p>Plain Java on purpose: {@code CaptureCoreCheck} unit-checks the geometry
 * on a regular JVM without an Android runtime.
 */
final class LetterboxGeometry {
    private final int videoWidth;
    private final int videoHeight;
    private final int displayWidth;
    private final int displayHeight;
    private final int contentWidth;
    private final int contentHeight;
    private final int offsetX;
    private final int offsetY;

    private LetterboxGeometry(
        int videoWidth,
        int videoHeight,
        int displayWidth,
        int displayHeight,
        int contentWidth,
        int contentHeight,
        int offsetX,
        int offsetY
    ) {
        this.videoWidth = videoWidth;
        this.videoHeight = videoHeight;
        this.displayWidth = displayWidth;
        this.displayHeight = displayHeight;
        this.contentWidth = contentWidth;
        this.contentHeight = contentHeight;
        this.offsetX = offsetX;
        this.offsetY = offsetY;
    }

    /**
     * Fits a {@code displayWidth x displayHeight} source into a
     * {@code videoWidth x videoHeight} frame (contain/fit, never crop).
     */
    static LetterboxGeometry fit(
        int videoWidth,
        int videoHeight,
        int displayWidth,
        int displayHeight
    ) {
        if (videoWidth <= 0 || videoHeight <= 0) {
            throw new IllegalArgumentException(
                "video size must be positive, got " + videoWidth + "x" + videoHeight
            );
        }
        if (displayWidth <= 0 || displayHeight <= 0) {
            throw new IllegalArgumentException(
                "display size must be positive, got " + displayWidth + "x"
                    + displayHeight
            );
        }

        final double scale = Math.min(
            videoWidth / (double) displayWidth,
            videoHeight / (double) displayHeight
        );
        // Keep the content inside the frame even after integer rounding.
        final int contentWidth = Math.min(
            videoWidth,
            Math.max(1, (int) Math.round(displayWidth * scale))
        );
        final int contentHeight = Math.min(
            videoHeight,
            Math.max(1, (int) Math.round(displayHeight * scale))
        );
        final int offsetX = Math.max(0, (videoWidth - contentWidth) / 2);
        final int offsetY = Math.max(0, (videoHeight - contentHeight) / 2);
        return new LetterboxGeometry(
            videoWidth,
            videoHeight,
            displayWidth,
            displayHeight,
            contentWidth,
            contentHeight,
            offsetX,
            offsetY
        );
    }

    /** Geometry for a video frame that already matches the display exactly. */
    static LetterboxGeometry identity(int width, int height) {
        return fit(width, height, width, height);
    }

    /**
     * Orients a display size to the orientation of a reference display size.
     *
     * <p>{@code Display.getRealSize(Point)} reports the physical panel in its
     * natural orientation, while the mirrored content follows the current
     * logical orientation. The letterbox has to match the mirrored content, so
     * the real size is swapped when the orientations differ; an already oriented
     * size is returned unchanged. This keeps the verified 1280x720 / 2800x2000
     * mapping intact while still following a rotation.
     *
     * @return a new {@code {width, height}} pair
     */
    static int[] orient(
        int width,
        int height,
        int referenceWidth,
        int referenceHeight
    ) {
        if (width <= 0 || height <= 0 || referenceWidth <= 0 || referenceHeight <= 0) {
            return new int[] {width, height};
        }
        final boolean wide = width >= height;
        final boolean referenceWide = referenceWidth >= referenceHeight;
        if (wide == referenceWide) {
            return new int[] {width, height};
        }
        return new int[] {height, width};
    }

    int videoWidth() {
        return videoWidth;
    }

    int videoHeight() {
        return videoHeight;
    }

    int displayWidth() {
        return displayWidth;
    }

    int displayHeight() {
        return displayHeight;
    }

    int contentWidth() {
        return contentWidth;
    }

    int contentHeight() {
        return contentHeight;
    }

    int offsetX() {
        return offsetX;
    }

    int offsetY() {
        return offsetY;
    }

    /** True when the frame carries letterbox/pillarbox bars. */
    boolean hasPadding() {
        return offsetX > 0 || offsetY > 0 || contentWidth < videoWidth
            || contentHeight < videoHeight;
    }

    /** Normalized (0..1) video x to display pixels. */
    int displayXFor(double normalizedX) {
        return displayXForVideo(normalizedX * videoWidth);
    }

    /** Normalized (0..1) video y to display pixels. */
    int displayYFor(double normalizedY) {
        return displayYForVideo(normalizedY * videoHeight);
    }

    /** Video-frame x in pixels to display pixels, with the bars removed. */
    int displayXForVideo(double videoX) {
        return mapAxis(videoX - offsetX, contentWidth, displayWidth);
    }

    /** Video-frame y in pixels to display pixels, with the bars removed. */
    int displayYForVideo(double videoY) {
        return mapAxis(videoY - offsetY, contentHeight, displayHeight);
    }

    /**
     * Removes the padding, clamps to the content box and scales to display
     * pixels. Clamping keeps a pointer that sits on a bar pinned to the nearest
     * display edge instead of injecting out-of-range coordinates.
     */
    static int mapAxis(double videoCoordinate, int contentLength, int displayLength) {
        if (contentLength <= 0 || displayLength <= 0) {
            return 0;
        }
        double ratio = videoCoordinate / (double) contentLength;
        if (ratio < 0d) {
            ratio = 0d;
        } else if (ratio > 1d) {
            ratio = 1d;
        }
        return (int) Math.round(ratio * (displayLength - 1));
    }

    /** One-line summary for the server log. */
    String describe() {
        return "video=" + videoWidth + "x" + videoHeight
            + " content=" + contentWidth + "x" + contentHeight
            + " offset=(" + offsetX + "," + offsetY + ")"
            + " display=" + displayWidth + "x" + displayHeight;
    }

    @Override
    public boolean equals(Object other) {
        if (this == other) {
            return true;
        }
        if (!(other instanceof LetterboxGeometry)) {
            return false;
        }
        final LetterboxGeometry that = (LetterboxGeometry) other;
        return videoWidth == that.videoWidth
            && videoHeight == that.videoHeight
            && displayWidth == that.displayWidth
            && displayHeight == that.displayHeight
            && contentWidth == that.contentWidth
            && contentHeight == that.contentHeight
            && offsetX == that.offsetX
            && offsetY == that.offsetY;
    }

    @Override
    public int hashCode() {
        int result = videoWidth;
        result = 31 * result + videoHeight;
        result = 31 * result + displayWidth;
        result = 31 * result + displayHeight;
        result = 31 * result + contentWidth;
        result = 31 * result + contentHeight;
        result = 31 * result + offsetX;
        result = 31 * result + offsetY;
        return result;
    }

    @Override
    public String toString() {
        return "LetterboxGeometry(" + describe() + ")";
    }
}

package com.example.screencast.server;

import java.io.IOException;

/**
 * Receives one encoded H.264 NAL unit at a time.
 *
 * <p>Implementations must write the exact NAL bytes without an Annex-B start
 * code. SPS and PPS are delivered as normal NAL units before the first IDR.
 */
@FunctionalInterface
public interface NalUnitSink {
    void writeNalUnit(byte[] nalUnit) throws IOException;
}

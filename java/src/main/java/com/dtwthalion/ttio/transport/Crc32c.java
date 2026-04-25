/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.transport;

/**
 * CRC-32C (Castagnoli, reflected polynomial 0x1EDC6F41) software
 * implementation. Matches Python {@code google-crc32c} and the
 * reflected-polynomial definition used by {@code java.util.zip.CRC32C}
 * (JDK 9+). Bundled here to keep the transport codec compilable on
 * older JDKs / environments without loading the java.util.zip CRC32C
 * class.
 */
final class Crc32c {

    private static final int POLY = 0x82F63B78;
    private static final int[] TABLE;

    static {
        int[] t = new int[256];
        for (int b = 0; b < 256; b++) {
            int crc = b;
            for (int i = 0; i < 8; i++) {
                crc = (crc >>> 1) ^ ((crc & 1) != 0 ? POLY : 0);
            }
            t[b] = crc;
        }
        TABLE = t;
    }

    private Crc32c() {}

    /** Compute CRC-32C of the full byte array. */
    static int compute(byte[] data) {
        int crc = 0xFFFFFFFF;
        for (byte b : data) {
            crc = (crc >>> 8) ^ TABLE[(crc ^ (b & 0xFF)) & 0xFF];
        }
        return crc ^ 0xFFFFFFFF;
    }
}

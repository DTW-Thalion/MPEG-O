/*
 * TTI-O Java Implementation.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.MiniJson;

import java.util.TreeMap;

/**
 * Per-AccessUnit summary statistics — every field is derivable from
 * an {@link AccessUnit} without decoding signal-channel payload.
 * Used by the workbench server's {@code stats-only} and
 * {@code stats-with-payload} download modes.
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Objective-C: {@code TTIOAUStats}</li>
 *   <li>Python:      {@code ttio.transport.stats.AUStats}</li>
 * </ul>
 *
 * <p>{@link #jsonString} produces a byte-stable form: sorted keys,
 * no whitespace.
 */
public final class AUStats {

    private static final int SPECTRUM_CLASS_MS_IMAGE_PIXEL = 4;
    private static final int SPECTRUM_CLASS_GENOMIC_READ   = 5;

    public final long auSequence;          // wire u32
    public final int  spectrumClass;       // wire u8
    public final int  msLevel;             // wire u8
    public final int  polarity;            // wire u8
    public final double retentionTime;
    public final double precursorMz;
    public final int  precursorCharge;     // wire u8
    public final double ionMobility;
    public final double basePeakIntensity;
    public final long channelCount;        // derived
    public final long totalElements;       // derived
    public final long payloadBytes;        // derived

    // GenomicRead suffix (spectrum_class == 5 only).
    public final String chromosome;        // "" / null otherwise
    public final long   position;          // i64
    public final int    mappingQuality;    // u8
    public final int    flags;             // u16

    // MSImagePixel coords (spectrum_class == 4 only).
    public final long pixelX;              // wire u32 → Java long for unsigned
    public final long pixelY;
    public final long pixelZ;

    private AUStats(long auSequence,
                    int spectrumClass, int msLevel, int polarity,
                    double retentionTime, double precursorMz,
                    int precursorCharge, double ionMobility,
                    double basePeakIntensity,
                    long channelCount, long totalElements, long payloadBytes,
                    String chromosome, long position,
                    int mappingQuality, int flags,
                    long pixelX, long pixelY, long pixelZ) {
        this.auSequence = auSequence;
        this.spectrumClass = spectrumClass;
        this.msLevel = msLevel;
        this.polarity = polarity;
        this.retentionTime = retentionTime;
        this.precursorMz = precursorMz;
        this.precursorCharge = precursorCharge;
        this.ionMobility = ionMobility;
        this.basePeakIntensity = basePeakIntensity;
        this.channelCount = channelCount;
        this.totalElements = totalElements;
        this.payloadBytes = payloadBytes;
        this.chromosome = chromosome;
        this.position = position;
        this.mappingQuality = mappingQuality;
        this.flags = flags;
        this.pixelX = pixelX;
        this.pixelY = pixelY;
        this.pixelZ = pixelZ;
    }

    /** Pure projection — never decodes channel payload. */
    public static AUStats fromAccessUnit(AccessUnit au, long auSequence) {
        long totalElements = 0L;
        long payloadBytes = 0L;
        for (ChannelData ch : au.channels) {
            totalElements += (long) ch.nElements;
            payloadBytes  += (long) ch.data.length;
        }
        String chromosome = null;
        long position = 0L;
        int mappingQuality = 0;
        int flags = 0;
        if (au.spectrumClass == SPECTRUM_CLASS_GENOMIC_READ) {
            chromosome = (au.chromosome == null) ? "" : au.chromosome;
            position = au.position;
            mappingQuality = au.mappingQuality & 0xFF;
            flags = au.flags & 0xFFFF;
        }
        long pixelX = 0L, pixelY = 0L, pixelZ = 0L;
        if (au.spectrumClass == SPECTRUM_CLASS_MS_IMAGE_PIXEL) {
            pixelX = au.pixelX & 0xFFFFFFFFL;
            pixelY = au.pixelY & 0xFFFFFFFFL;
            pixelZ = au.pixelZ & 0xFFFFFFFFL;
        }
        return new AUStats(
            auSequence & 0xFFFFFFFFL,
            au.spectrumClass & 0xFF,
            au.msLevel & 0xFF,
            au.polarity & 0xFF,
            au.retentionTime,
            au.precursorMz,
            au.precursorCharge & 0xFF,
            au.ionMobility,
            au.basePeakIntensity,
            (long) au.channels.size(),
            totalElements,
            payloadBytes,
            chromosome,
            position,
            mappingQuality,
            flags,
            pixelX, pixelY, pixelZ
        );
    }

    /** Byte-stable JSON: sorted keys (TreeMap insertion order
     *  matches lexicographic), compact form via
     *  {@link MiniJson#encode}. Mirrors ObjC
     *  {@code NSJSONWritingSortedKeys} and Python
     *  {@code json.dumps(..., sort_keys=True, separators=(",",":"))}. */
    public String jsonString() {
        TreeMap<String, Object> m = new TreeMap<>();
        m.put("au_sequence", auSequence);
        m.put("spectrum_class", (long) spectrumClass);
        m.put("ms_level", (long) msLevel);
        m.put("polarity", (long) polarity);
        m.put("retention_time", retentionTime);
        m.put("precursor_mz", precursorMz);
        m.put("precursor_charge", (long) precursorCharge);
        m.put("ion_mobility", ionMobility);
        m.put("base_peak_intensity", basePeakIntensity);
        m.put("channel_count", channelCount);
        m.put("total_elements", totalElements);
        m.put("payload_bytes", payloadBytes);
        if (spectrumClass == SPECTRUM_CLASS_GENOMIC_READ) {
            m.put("chromosome", chromosome == null ? "" : chromosome);
            m.put("position", position);
            m.put("mapping_quality", (long) mappingQuality);
            m.put("flags", (long) flags);
        }
        if (spectrumClass == SPECTRUM_CLASS_MS_IMAGE_PIXEL) {
            m.put("pixel_x", pixelX);
            m.put("pixel_y", pixelY);
            m.put("pixel_z", pixelZ);
        }
        return MiniJson.encode(m);
    }

    public static String jsonStringFor(AccessUnit au, long auSequence) {
        return fromAccessUnit(au, auSequence).jsonString();
    }
}

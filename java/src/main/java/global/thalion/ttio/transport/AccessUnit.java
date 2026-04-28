/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Transport-layer Access Unit: one spectrum as a transport payload.
 *
 * <p>Wire value for {@code spectrumClass}: 0=MassSpectrum,
 * 1=NMRSpectrum, 2=NMR2D, 3=FID, 4=MSImagePixel, 5=GenomicRead
 * (v0.11 M79; suffix carrying chromosome / position / mapq / flags
 * shipped in M89.1).</p>
 *
 * <p>Wire value for {@code polarity} (differs from
 * {@link global.thalion.ttio.Enums.Polarity} which uses -1 for negative;
 * the wire uses nonneg only): 0=positive, 1=negative, 2=unknown.</p>
 */
public final class AccessUnit {

    public final int spectrumClass;
    public final int acquisitionMode;
    public final int msLevel;
    public final int polarity;
    public final double retentionTime;
    public final double precursorMz;
    public final int precursorCharge;
    public final double ionMobility;
    public final double basePeakIntensity;
    public final List<ChannelData> channels;

    public final long pixelX;
    public final long pixelY;
    public final long pixelZ;

    // M89.1 GenomicRead suffix (written only when {@code spectrumClass == 5}).
    // chromosome is variable-length (uint16 length-prefixed UTF-8).
    // position is signed int64 to match the BAM convention of -1 for
    // unmapped reads. mapping_quality is uint8 (BAM range 0-255).
    // flags is uint16 (SAM/BAM bit flags).
    public final String chromosome;
    public final long position;
    public final int mappingQuality;
    public final int flags;

    // M90.9 mate extension (written only when {@code spectrumClass == 5}).
    // Optional on the wire — when absent (M89.1 fixture or empty AU)
    // these default to BAM unmapped sentinels: -1 mate_position,
    // 0 template_length. Decoder is OPTIONAL: payloads ending right
    // after flags decode unchanged.
    public final long matePosition;
    public final int templateLength;

    /** Backwards-compatible constructor (pre-M89.1) for non-genomic AUs.
     *  Genomic suffix fields default to "" / 0 / 0 / 0; mate extension
     *  fields default to -1 / 0. */
    public AccessUnit(int spectrumClass, int acquisitionMode, int msLevel, int polarity,
                       double retentionTime, double precursorMz, int precursorCharge,
                       double ionMobility, double basePeakIntensity,
                       List<ChannelData> channels,
                       long pixelX, long pixelY, long pixelZ) {
        this(spectrumClass, acquisitionMode, msLevel, polarity,
             retentionTime, precursorMz, precursorCharge,
             ionMobility, basePeakIntensity, channels,
             pixelX, pixelY, pixelZ,
             "", 0L, 0, 0, -1L, 0);
    }

    /** M89.1 constructor including GenomicRead suffix fields. Mate
     *  extension fields default to -1 / 0 (preserves M89.1 wire
     *  fixtures). */
    public AccessUnit(int spectrumClass, int acquisitionMode, int msLevel, int polarity,
                       double retentionTime, double precursorMz, int precursorCharge,
                       double ionMobility, double basePeakIntensity,
                       List<ChannelData> channels,
                       long pixelX, long pixelY, long pixelZ,
                       String chromosome, long position,
                       int mappingQuality, int flags) {
        this(spectrumClass, acquisitionMode, msLevel, polarity,
             retentionTime, precursorMz, precursorCharge,
             ionMobility, basePeakIntensity, channels,
             pixelX, pixelY, pixelZ,
             chromosome, position, mappingQuality, flags,
             -1L, 0);
    }

    /** M90.9 full constructor including the mate-extension fields. */
    public AccessUnit(int spectrumClass, int acquisitionMode, int msLevel, int polarity,
                       double retentionTime, double precursorMz, int precursorCharge,
                       double ionMobility, double basePeakIntensity,
                       List<ChannelData> channels,
                       long pixelX, long pixelY, long pixelZ,
                       String chromosome, long position,
                       int mappingQuality, int flags,
                       long matePosition, int templateLength) {
        this.spectrumClass = spectrumClass;
        this.acquisitionMode = acquisitionMode;
        this.msLevel = msLevel;
        this.polarity = polarity;
        this.retentionTime = retentionTime;
        this.precursorMz = precursorMz;
        this.precursorCharge = precursorCharge;
        this.ionMobility = ionMobility;
        this.basePeakIntensity = basePeakIntensity;
        this.channels = Collections.unmodifiableList(new ArrayList<>(channels));
        this.pixelX = pixelX;
        this.pixelY = pixelY;
        this.pixelZ = pixelZ;
        this.chromosome = chromosome == null ? "" : chromosome;
        this.position = position;
        this.mappingQuality = mappingQuality;
        this.flags = flags;
        this.matePosition = matePosition;
        this.templateLength = templateLength;
    }

    public byte[] encode() {
        int size = 38;
        for (ChannelData ch : channels) size += ch.encodedSize();
        if (spectrumClass == 4) {
            size += 12;
        } else if (spectrumClass == 5) {
            // M89.1: uint16 chromosome length + chromosome bytes +
            // int64 position + uint8 mapq + uint16 flags = 13 + |chrom|.
            // M90.9: + int64 mate_position + int32 template_length = +12.
            size += 2 + chromosome.getBytes(StandardCharsets.UTF_8).length + 8 + 1 + 2;
            size += 8 + 4;
        }
        ByteBuffer buf = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        buf.put((byte) (spectrumClass & 0xFF));
        buf.put((byte) (acquisitionMode & 0xFF));
        buf.put((byte) (msLevel & 0xFF));
        buf.put((byte) (polarity & 0xFF));
        buf.putDouble(retentionTime);
        buf.putDouble(precursorMz);
        buf.put((byte) (precursorCharge & 0xFF));
        buf.putDouble(ionMobility);
        buf.putDouble(basePeakIntensity);
        buf.put((byte) (channels.size() & 0xFF));
        for (ChannelData ch : channels) ch.appendTo(buf);
        if (spectrumClass == 4) {
            buf.putInt((int) (pixelX & 0xFFFFFFFFL));
            buf.putInt((int) (pixelY & 0xFFFFFFFFL));
            buf.putInt((int) (pixelZ & 0xFFFFFFFFL));
        } else if (spectrumClass == 5) {
            byte[] chromBytes = chromosome.getBytes(StandardCharsets.UTF_8);
            buf.putShort((short) (chromBytes.length & 0xFFFF));
            buf.put(chromBytes);
            buf.putLong(position);
            buf.put((byte) (mappingQuality & 0xFF));
            buf.putShort((short) (flags & 0xFFFF));
            // M90.9 mate extension — always emitted by Java writers
            // post-M90.9. Decoders fall back to defaults when missing
            // so M89.1 fixtures still decode.
            buf.putLong(matePosition);
            buf.putInt(templateLength);
        }
        return buf.array();
    }

    public static AccessUnit decode(byte[] bytes) {
        if (bytes.length < 38) {
            throw new IllegalArgumentException("access unit payload too short: " + bytes.length);
        }
        ByteBuffer buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        int spectrumClass = buf.get() & 0xFF;
        int acquisitionMode = buf.get() & 0xFF;
        int msLevel = buf.get() & 0xFF;
        int polarity = buf.get() & 0xFF;
        double retentionTime = buf.getDouble();
        double precursorMz = buf.getDouble();
        int precursorCharge = buf.get() & 0xFF;
        double ionMobility = buf.getDouble();
        double basePeakIntensity = buf.getDouble();
        int nChannels = buf.get() & 0xFF;
        List<ChannelData> channels = new ArrayList<>(nChannels);
        for (int i = 0; i < nChannels; i++) channels.add(ChannelData.decode(buf));
        long pixelX = 0, pixelY = 0, pixelZ = 0;
        String chromosome = "";
        long position = 0L;
        int mappingQuality = 0;
        int flags = 0;
        // M90.9 mate extension defaults — match the constructor
        // defaults so M89.1 AUs decode unchanged.
        long matePosition = -1L;
        int templateLength = 0;
        if (spectrumClass == 4) {
            if (bytes.length - buf.position() < 12) {
                throw new IllegalArgumentException("MSImagePixel AU missing pixel coordinates");
            }
            pixelX = buf.getInt() & 0xFFFFFFFFL;
            pixelY = buf.getInt() & 0xFFFFFFFFL;
            pixelZ = buf.getInt() & 0xFFFFFFFFL;
        } else if (spectrumClass == 5) {
            // M89.1: uint16 chromosome length + chromosome bytes +
            // int64 position + uint8 mapq + uint16 flags.
            if (bytes.length - buf.position() < 2) {
                throw new IllegalArgumentException(
                    "GenomicRead AU missing chromosome length prefix");
            }
            int chromLen = buf.getShort() & 0xFFFF;
            if (bytes.length - buf.position() < chromLen) {
                throw new IllegalArgumentException(
                    "GenomicRead AU chromosome bytes truncated: need "
                    + chromLen + " bytes, have " + (bytes.length - buf.position()));
            }
            byte[] chromBytes = new byte[chromLen];
            buf.get(chromBytes);
            chromosome = new String(chromBytes, StandardCharsets.UTF_8);
            // Fixed-suffix: 8 (position) + 1 (mapq) + 2 (flags) = 11 bytes.
            if (bytes.length - buf.position() < 11) {
                throw new IllegalArgumentException(
                    "GenomicRead AU missing position/mapq/flags suffix");
            }
            position = buf.getLong();
            mappingQuality = buf.get() & 0xFF;
            flags = buf.getShort() & 0xFFFF;
            // M90.9 mate extension — optional. M89.1 payloads end
            // right after flags; M90.9+ payloads carry 12 more bytes
            // (int64 mate_position + int32 template_length).
            if (bytes.length - buf.position() >= 12) {
                matePosition = buf.getLong();
                templateLength = buf.getInt();
            }
        }
        return new AccessUnit(spectrumClass, acquisitionMode, msLevel, polarity,
                retentionTime, precursorMz, precursorCharge, ionMobility,
                basePeakIntensity, channels, pixelX, pixelY, pixelZ,
                chromosome, position, mappingQuality, flags,
                matePosition, templateLength);
    }
}

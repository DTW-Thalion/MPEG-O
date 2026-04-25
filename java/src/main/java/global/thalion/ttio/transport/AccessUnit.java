/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Transport-layer Access Unit: one spectrum as a transport payload.
 *
 * <p>Wire value for {@code spectrumClass}: 0=MassSpectrum,
 * 1=NMRSpectrum, 2=NMR2D, 3=FID, 4=MSImagePixel, 5=GenomicRead
 * (v0.11 M79).</p>
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

    public AccessUnit(int spectrumClass, int acquisitionMode, int msLevel, int polarity,
                       double retentionTime, double precursorMz, int precursorCharge,
                       double ionMobility, double basePeakIntensity,
                       List<ChannelData> channels,
                       long pixelX, long pixelY, long pixelZ) {
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
    }

    public byte[] encode() {
        int size = 38;
        for (ChannelData ch : channels) size += ch.encodedSize();
        if (spectrumClass == 4) size += 12;
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
        if (spectrumClass == 4) {
            if (bytes.length - buf.position() < 12) {
                throw new IllegalArgumentException("MSImagePixel AU missing pixel coordinates");
            }
            pixelX = buf.getInt() & 0xFFFFFFFFL;
            pixelY = buf.getInt() & 0xFFFFFFFFL;
            pixelZ = buf.getInt() & 0xFFFFFFFFL;
        }
        return new AccessUnit(spectrumClass, acquisitionMode, msLevel, polarity,
                retentionTime, precursorMz, precursorCharge, ionMobility,
                basePeakIntensity, channels, pixelX, pixelY, pixelZ);
    }
}

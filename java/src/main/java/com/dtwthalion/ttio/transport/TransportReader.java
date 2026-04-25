/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio.transport;

import com.dtwthalion.ttio.AcquisitionRun;
import com.dtwthalion.ttio.Enums;
import com.dtwthalion.ttio.InstrumentConfig;
import com.dtwthalion.ttio.SpectralDataset;
import com.dtwthalion.ttio.SpectrumIndex;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.FileInputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Deserialises a transport byte stream into {@link PacketRecord} values
 * or materializes the stream into a {@link SpectralDataset}.
 *
 * <p>Cross-language equivalents: Python
 * {@code ttio.transport.codec.TransportReader}, Objective-C
 * {@code TTIOTransportReader}.</p>
 */
public final class TransportReader implements AutoCloseable {

    private final InputStream in;
    private final boolean ownsStream;

    public TransportReader(InputStream in) {
        this.in = in;
        this.ownsStream = false;
    }

    public TransportReader(Path path) throws IOException {
        this.in = new FileInputStream(path.toFile());
        this.ownsStream = true;
    }

    public TransportReader(byte[] data) {
        this.in = new ByteArrayInputStream(data);
        this.ownsStream = true;
    }

    @Override
    public void close() throws IOException {
        if (ownsStream) in.close();
    }

    // ---------------------------------------------------------- record

    /** One parsed packet as header + payload. */
    public static final class PacketRecord {
        public final PacketHeader header;
        public final byte[] payload;
        public PacketRecord(PacketHeader header, byte[] payload) {
            this.header = header;
            this.payload = payload;
        }
    }

    // ---------------------------------------------------------- iteration

    public List<PacketRecord> readAllPackets() throws IOException {
        List<PacketRecord> out = new ArrayList<>();
        while (true) {
            byte[] headerBytes = in.readNBytes(PacketHeader.HEADER_SIZE);
            if (headerBytes.length == 0) return out;
            if (headerBytes.length < PacketHeader.HEADER_SIZE) {
                throw new IOException("truncated header: " + headerBytes.length);
            }
            PacketHeader header = PacketHeader.decode(headerBytes);
            byte[] payload = in.readNBytes((int) header.payloadLength);
            if (payload.length != header.payloadLength) {
                throw new IOException("truncated payload: "
                        + payload.length + "/" + header.payloadLength);
            }
            if ((header.flags & PacketHeader.FLAG_HAS_CHECKSUM) != 0) {
                byte[] crcBytes = in.readNBytes(4);
                if (crcBytes.length != 4) throw new IOException("truncated CRC-32C");
                int expected = ByteBuffer.wrap(crcBytes).order(ByteOrder.LITTLE_ENDIAN).getInt();
                int actual = Crc32c.compute(payload);
                if (expected != actual) {
                    throw new IOException("CRC-32C mismatch on packet type "
                            + header.packetType + ": expected=" + Integer.toHexString(expected)
                            + ", got=" + Integer.toHexString(actual));
                }
            }
            out.add(new PacketRecord(header, payload));
            if (header.packetType == PacketType.END_OF_STREAM) return out;
        }
    }

    // ---------------------------------------------------------- materialize

    public SpectralDataset materializeTo(String outputPath) throws IOException {
        List<PacketRecord> packets = readAllPackets();
        String title = "";
        String isa = "";
        Map<Integer, DatasetMeta> datasetMetas = new LinkedHashMap<>();
        Map<Integer, RunAccumulator> runAccs = new LinkedHashMap<>();
        Map<Integer, Long> lastSeq = new LinkedHashMap<>();
        boolean sawStreamHeader = false;

        for (PacketRecord rec : packets) {
            PacketHeader h = rec.header;
            ByteBuffer buf = ByteBuffer.wrap(rec.payload).order(ByteOrder.LITTLE_ENDIAN);

            if (h.packetType == PacketType.STREAM_HEADER) {
                if (sawStreamHeader) continue;
                sawStreamHeader = true;
                readLEString(buf, 2); // format_version
                title = readLEString(buf, 2);
                isa = readLEString(buf, 2);
                int nFeatures = buf.getShort() & 0xFFFF;
                for (int i = 0; i < nFeatures; i++) readLEString(buf, 2);
                // n_datasets — we don't need it; the headers carry their own ids.
                continue;
            }
            if (!sawStreamHeader) {
                throw new IOException("first packet must be StreamHeader; got " + h.packetType);
            }

            if (h.packetType == PacketType.DATASET_HEADER) {
                int datasetId = buf.getShort() & 0xFFFF;
                String name = readLEString(buf, 2);
                int acqMode = buf.get() & 0xFF;
                String spectrumClass = readLEString(buf, 2);
                int nch = buf.get() & 0xFF;
                List<String> channelNames = new ArrayList<>(nch);
                for (int i = 0; i < nch; i++) channelNames.add(readLEString(buf, 2));
                readLEString(buf, 4); // instrument_json
                long expected = buf.getInt() & 0xFFFFFFFFL;
                datasetMetas.put(datasetId, new DatasetMeta(
                        datasetId, name, acqMode, spectrumClass, channelNames, expected));
                runAccs.put(datasetId, new RunAccumulator(channelNames));
                continue;
            }
            if (h.packetType == PacketType.ACCESS_UNIT) {
                DatasetMeta meta = datasetMetas.get(h.datasetId);
                if (meta == null) {
                    throw new IOException("AccessUnit before DatasetHeader for id " + h.datasetId);
                }
                Long prev = lastSeq.get(h.datasetId);
                if (prev != null && h.auSequence <= prev) {
                    throw new IOException("non-monotonic au_sequence in dataset "
                            + h.datasetId + ": prev=" + prev + ", got=" + h.auSequence);
                }
                lastSeq.put(h.datasetId, h.auSequence);
                AccessUnit au = AccessUnit.decode(rec.payload);
                runAccs.get(h.datasetId).ingest(au);
                continue;
            }
            if (h.packetType == PacketType.END_OF_DATASET) continue;
            if (h.packetType == PacketType.END_OF_STREAM) break;
            // Annotation / Provenance / Chromatogram / Protection: skipped in M67.
        }

        List<AcquisitionRun> runs = new ArrayList<>();
        for (Map.Entry<Integer, DatasetMeta> e : datasetMetas.entrySet()) {
            DatasetMeta meta = e.getValue();
            RunAccumulator acc = runAccs.get(e.getKey());
            SpectrumIndex idx = acc.toSpectrumIndex();
            Map<String, double[]> channelMap = acc.toChannelMap();
            InstrumentConfig cfg = new InstrumentConfig("", "", "", "", "", "");
            Enums.AcquisitionMode acqMode =
                    Enums.AcquisitionMode.values()[
                            Math.min(meta.acquisitionMode,
                                    Enums.AcquisitionMode.values().length - 1)];
            runs.add(new AcquisitionRun(meta.name, acqMode, idx, cfg,
                    channelMap, List.of(), List.of(), "", 0.0));
        }

        return SpectralDataset.create(outputPath, title, isa, runs,
                List.of(), List.of(), List.of());
    }

    // ---------------------------------------------------------- helpers

    private static String readLEString(ByteBuffer buf, int widthBytes) {
        int len;
        if (widthBytes == 2) len = buf.getShort() & 0xFFFF;
        else                  len = buf.getInt();
        byte[] b = new byte[len];
        buf.get(b);
        return new String(b, StandardCharsets.UTF_8);
    }

    // ---------------------------------------------------------- accumulators

    private static final class DatasetMeta {
        final int datasetId;
        final String name;
        final int acquisitionMode;
        final String spectrumClass;
        final List<String> channelNames;
        final long expectedAUCount;
        DatasetMeta(int id, String n, int mode, String cls, List<String> ch, long exp) {
            datasetId = id; name = n; acquisitionMode = mode; spectrumClass = cls;
            channelNames = ch; expectedAUCount = exp;
        }
    }

    private static final class RunAccumulator {
        final List<String> channelNames;
        final Map<String, List<double[]>> perSpectrumChannels = new LinkedHashMap<>();
        long runningOffset = 0;
        final List<Long> offsets = new ArrayList<>();
        final List<Integer> lengths = new ArrayList<>();
        final List<Double> retentionTimes = new ArrayList<>();
        final List<Integer> msLevels = new ArrayList<>();
        final List<Integer> polarities = new ArrayList<>();
        final List<Double> precursorMzs = new ArrayList<>();
        final List<Integer> precursorCharges = new ArrayList<>();
        final List<Double> basePeakIntensities = new ArrayList<>();

        RunAccumulator(List<String> channelNames) {
            this.channelNames = channelNames;
            for (String c : channelNames) perSpectrumChannels.put(c, new ArrayList<>());
        }

        void ingest(AccessUnit au) {
            int length = 0;
            Map<String, double[]> perAu = new LinkedHashMap<>();
            for (ChannelData ch : au.channels) {
                if (ch.precision != Enums.Precision.FLOAT64.ordinal()) {
                    throw new IllegalStateException(
                            "reader supports FLOAT64 precision only");
                }
                byte[] raw;
                if (ch.compression == Enums.Compression.NONE.ordinal()) {
                    raw = ch.data;
                } else if (ch.compression == Enums.Compression.ZLIB.ordinal()) {
                    raw = zlibInflate(ch.data);
                } else {
                    throw new IllegalStateException(
                            "reader supports NONE/ZLIB compression only, got " + ch.compression);
                }
                int n = raw.length / 8;
                double[] arr = new double[n];
                ByteBuffer buf = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
                for (int k = 0; k < n; k++) arr[k] = buf.getDouble();
                perAu.put(ch.name, arr);
                if (length != 0 && length != n) {
                    throw new IllegalStateException(
                            "channels in one AU have mismatched lengths");
                }
                length = n;
            }
            offsets.add(runningOffset);
            lengths.add(length);
            runningOffset += length;
            for (String c : channelNames) {
                double[] arr = perAu.get(c);
                if (arr == null) arr = new double[length];
                perSpectrumChannels.get(c).add(arr);
            }
            retentionTimes.add(au.retentionTime);
            msLevels.add(au.msLevel);
            polarities.add(wireToPolarityInt(au.polarity));
            precursorMzs.add(au.precursorMz);
            precursorCharges.add(au.precursorCharge);
            basePeakIntensities.add(au.basePeakIntensity);
        }

        SpectrumIndex toSpectrumIndex() {
            int n = offsets.size();
            long[] off = new long[n];
            int[] len = new int[n];
            double[] rt = new double[n];
            int[] ms = new int[n];
            int[] pol = new int[n];
            double[] pmz = new double[n];
            int[] pc = new int[n];
            double[] bpi = new double[n];
            for (int i = 0; i < n; i++) {
                off[i] = offsets.get(i);
                len[i] = lengths.get(i);
                rt[i] = retentionTimes.get(i);
                ms[i] = msLevels.get(i);
                pol[i] = polarities.get(i);
                pmz[i] = precursorMzs.get(i);
                pc[i] = precursorCharges.get(i);
                bpi[i] = basePeakIntensities.get(i);
            }
            return new SpectrumIndex(n, off, len, rt, ms, pol, pmz, pc, bpi);
        }

        Map<String, double[]> toChannelMap() {
            Map<String, double[]> out = new LinkedHashMap<>();
            for (String c : channelNames) {
                List<double[]> chunks = perSpectrumChannels.get(c);
                int total = 0;
                for (double[] d : chunks) total += d.length;
                double[] flat = new double[total];
                int off = 0;
                for (double[] d : chunks) {
                    System.arraycopy(d, 0, flat, off, d.length);
                    off += d.length;
                }
                out.put(c, flat);
            }
            return out;
        }
    }

    private static byte[] zlibInflate(byte[] input) {
        java.util.zip.Inflater inf = new java.util.zip.Inflater();
        inf.setInput(input);
        byte[] buf = new byte[Math.max(64, input.length * 4)];
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        try {
            while (!inf.finished()) {
                int n = inf.inflate(buf);
                if (n == 0) {
                    if (inf.needsInput() || inf.needsDictionary()) {
                        throw new IllegalStateException("zlib underflow");
                    }
                }
                out.write(buf, 0, n);
            }
        } catch (java.util.zip.DataFormatException e) {
            throw new IllegalStateException("zlib inflate failed", e);
        } finally {
            inf.end();
        }
        return out.toByteArray();
    }

    private static int wireToPolarityInt(int wire) {
        return switch (wire) {
            case 0 -> Enums.Polarity.POSITIVE.intValue();
            case 1 -> Enums.Polarity.NEGATIVE.intValue();
            default -> Enums.Polarity.UNKNOWN.intValue();
        };
    }
}

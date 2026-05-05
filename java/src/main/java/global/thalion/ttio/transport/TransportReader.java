/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.MiniJson;
import global.thalion.ttio.codecs.BasePack;
import global.thalion.ttio.codecs.Rans;
import global.thalion.ttio.genomics.WrittenGenomicRun;

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
        // M89.2: parallel accumulator for genomic datasets.
        Map<Integer, GenomicAccumulator> genomicAccs = new LinkedHashMap<>();
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
                // n_datasets - we don't need it; the headers carry their own ids.
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
                String instrumentJson = readLEString(buf, 4);
                long expected = buf.getInt() & 0xFFFFFFFFL;
                datasetMetas.put(datasetId, new DatasetMeta(
                        datasetId, name, acqMode, spectrumClass, channelNames,
                        instrumentJson, expected));
                // M89.2: genomic datasets get a parallel accumulator.
                if ("TTIOGenomicRead".equals(spectrumClass)) {
                    genomicAccs.put(datasetId, new GenomicAccumulator());
                } else {
                    runAccs.put(datasetId, new RunAccumulator(channelNames));
                }
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
                if (genomicAccs.containsKey(h.datasetId)) {
                    genomicAccs.get(h.datasetId).ingest(au);
                } else {
                    runAccs.get(h.datasetId).ingest(au);
                }
                continue;
            }
            if (h.packetType == PacketType.END_OF_DATASET) continue;
            if (h.packetType == PacketType.END_OF_STREAM) break;
            // Annotation / Provenance / Chromatogram / Protection: skipped in M67.
        }

        List<AcquisitionRun> runs = new ArrayList<>();
        for (Map.Entry<Integer, DatasetMeta> e : datasetMetas.entrySet()) {
            DatasetMeta meta = e.getValue();
            if (genomicAccs.containsKey(e.getKey())) continue;
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

        // M89.2: build WrittenGenomicRun for each genomic dataset.
        List<WrittenGenomicRun> genomicRuns = new ArrayList<>();
        for (Map.Entry<Integer, GenomicAccumulator> e : genomicAccs.entrySet()) {
            DatasetMeta meta = datasetMetas.get(e.getKey());
            genomicRuns.add(e.getValue().toWrittenGenomicRun(meta));
        }

        // Create the file then re-open so the returned dataset's
        // genomic StorageGroup handles are live (the create() call
        // closes its read-side handles after writing - GenomicRun
        // would then fail to open signal_channels lazily).
        SpectralDataset created = SpectralDataset.create(
            outputPath, title, isa, runs, genomicRuns,
            List.of(), List.of(), List.of(),
            global.thalion.ttio.FeatureFlags.defaultCurrent());
        if (genomicRuns.isEmpty()) return created;
        created.close();
        return SpectralDataset.open(outputPath);
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
        final String instrumentJson;
        final long expectedAUCount;
        DatasetMeta(int id, String n, int mode, String cls, List<String> ch,
                    String instrumentJson, long exp) {
            datasetId = id; name = n; acquisitionMode = mode; spectrumClass = cls;
            channelNames = ch; this.instrumentJson = instrumentJson;
            expectedAUCount = exp;
        }
    }

    /** M89.2/M90.9: per-dataset accumulator for genomic AUs. Mirrors
     *  the Python {@code _new_genomic_accumulator} dict.
     *
     *  <p>M89.2: sequences and qualities ride as UINT8 channels; the
     *  suffix carries chromosome / position / mapq / flags.</p>
     *
     *  <p>M90.9: cigar / read_name / mate_chromosome ride as 3
     *  additional UINT8 string channels (per-AU). mate_position +
     *  template_length ride on the M90.9 mate extension at the end of
     *  the AU genomic suffix; the {@link AccessUnit#decode} path
     *  defaults them to -1 / 0 when absent (fixtures).</p>
     *
     *  <p>M90.10: dispatches on the wire {@code compression} byte to
     *  pick the M86 codec decoder (rANS / BASE_PACK) for the
     *  sequences + qualities channels. The 3 string channels are
     *  always uncompressed.</p> */
    private static final class GenomicAccumulator {
        final List<String> chromosomes = new ArrayList<>();
        final List<Long> positions = new ArrayList<>();
        final List<Integer> mappingQualities = new ArrayList<>();
        final List<Integer> flags = new ArrayList<>();
        final java.io.ByteArrayOutputStream sequences = new java.io.ByteArrayOutputStream();
        final java.io.ByteArrayOutputStream qualities = new java.io.ByteArrayOutputStream();
        final List<Long> offsets = new ArrayList<>();
        final List<Integer> lengths = new ArrayList<>();
        // M90.9 compound-field accumulators.
        final List<String> cigars = new ArrayList<>();
        final List<String> readNames = new ArrayList<>();
        final List<String> mateChroms = new ArrayList<>();
        final List<Long> matePositions = new ArrayList<>();
        final List<Integer> templateLengths = new ArrayList<>();
        long runningOffset = 0L;
        int acquisitionMode = 0;

        void ingest(AccessUnit au) {
            if (au.spectrumClass != 5) {
                throw new IllegalStateException(
                    "genomic accumulator received spectrum_class " + au.spectrumClass);
            }
            chromosomes.add(au.chromosome);
            positions.add(au.position);
            mappingQualities.add(au.mappingQuality);
            flags.add(au.flags);
            // M90.9: mate extension fields ride on the AU genomic suffix.
            matePositions.add(au.matePosition);
            templateLengths.add(au.templateLength);
            int length = 0;
            // M90.9: compound-string channels default to "" if absent
            // (an M89.2-era AU). Channel-name dispatch covers both
            // layouts.
            String cigarStr = "";
            String nameStr = "";
            String mateChrStr = "";
            for (ChannelData ch : au.channels) {
                if (ch.precision != Enums.Precision.UINT8.ordinal()) {
                    throw new IllegalStateException(
                        "genomic channel precision " + ch.precision
                        + " not yet supported (UINT8 only)");
                }
                // M90.10: dispatch on wire compression byte (NONE /
                // RANS_* / BASE_PACK). See decodeWireCodec.
                byte[] decoded = decodeWireCodec(ch.data, ch.compression);
                if ("sequences".equals(ch.name)) {
                    try { sequences.write(decoded); }
                    catch (java.io.IOException e) { throw new IllegalStateException(e); }
                    length = decoded.length;
                } else if ("qualities".equals(ch.name)) {
                    try { qualities.write(decoded); }
                    catch (java.io.IOException e) { throw new IllegalStateException(e); }
                    if (length == 0) length = decoded.length;
                } else if ("cigar".equals(ch.name)) {
                    cigarStr = new String(decoded, StandardCharsets.UTF_8);
                } else if ("read_name".equals(ch.name)) {
                    nameStr = new String(decoded, StandardCharsets.UTF_8);
                } else if ("mate_chromosome".equals(ch.name)) {
                    mateChrStr = new String(decoded, StandardCharsets.UTF_8);
                }
            }
            cigars.add(cigarStr);
            readNames.add(nameStr);
            mateChroms.add(mateChrStr);
            offsets.add(runningOffset);
            lengths.add(length);
            runningOffset += length;
        }

        /** M90.10: decode a wire payload encoded by
         *  {@code TransportWriter.applyWireCodec}. NONE → identity. */
        private static byte[] decodeWireCodec(byte[] payload, int codecId) {
            if (codecId == 0) return payload;  // NONE
            if (codecId == Enums.Compression.RANS_ORDER0.ordinal()
                    || codecId == Enums.Compression.RANS_ORDER1.ordinal()) {
                return Rans.decode(payload);
            }
            if (codecId == Enums.Compression.BASE_PACK.ordinal()) {
                return BasePack.decode(payload);
            }
            throw new UnsupportedOperationException(
                "decodeWireCodec: codec id " + codecId
                + " not supported for genomic UINT8");
        }

        WrittenGenomicRun toWrittenGenomicRun(DatasetMeta meta) {
            int n = chromosomes.size();
            long[] offsetsArr = new long[n];
            int[] lengthsArr = new int[n];
            long[] positionsArr = new long[n];
            byte[] mqArr = new byte[n];
            int[] flagsArr = new int[n];
            for (int i = 0; i < n; i++) {
                offsetsArr[i] = offsets.get(i);
                lengthsArr[i] = lengths.get(i);
                positionsArr[i] = positions.get(i);
                mqArr[i] = (byte) (mappingQualities.get(i) & 0xFF);
                flagsArr[i] = flags.get(i);
            }
            // M90.9: compound fields now round-trip on the wire. When
            // the source is an M89.2-era stream the per-AU decoders
            // default the missing strings to "" and the mate scalars
            // to -1 / 0 (preserved by AccessUnit.decode + the
            // accumulator defaults).
            long[] mateP = new long[n];
            int[] tlens = new int[n];
            for (int i = 0; i < n; i++) {
                mateP[i] = matePositions.get(i);
                tlens[i] = templateLengths.get(i);
            }
            List<String> cigarsOut = new ArrayList<>(cigars);
            List<String> readNamesOut = new ArrayList<>(readNames);
            List<String> mateChromsOut = new ArrayList<>(mateChroms);

            // Decode instrument_json metadata.
            String referenceUri = "", platform = "", sampleName = "", modality = "";
            try {
                Object parsed = MiniJson.parse(meta.instrumentJson);
                if (parsed instanceof Map<?, ?> mraw) {
                    @SuppressWarnings("unchecked")
                    Map<String, Object> m = (Map<String, Object>) mraw;
                    Object ru = m.get("reference_uri"); if (ru != null) referenceUri = ru.toString();
                    Object pl = m.get("platform"); if (pl != null) platform = pl.toString();
                    Object sn = m.get("sample_name"); if (sn != null) sampleName = sn.toString();
                    Object md = m.get("modality"); if (md != null) modality = md.toString();
                }
            } catch (Exception ignore) {
                // Unparseable instrument_json - leave defaults.
            }
            // modality not currently surfaced on WrittenGenomicRun's
            // constructor; the GenomicRun reader pulls it from the
            // file-level modality attribute (defaulted at write time).
            Enums.AcquisitionMode acqMode;
            try {
                acqMode = Enums.AcquisitionMode.values()[
                    Math.min(meta.acquisitionMode,
                             Enums.AcquisitionMode.values().length - 1)];
            } catch (Exception e) {
                acqMode = Enums.AcquisitionMode.GENOMIC_WGS;
            }
            return new WrittenGenomicRun(
                acqMode, referenceUri, platform, sampleName,
                positionsArr, mqArr, flagsArr,
                sequences.toByteArray(), qualities.toByteArray(),
                offsetsArr, lengthsArr,
                cigarsOut, readNamesOut, mateChromsOut, mateP, tlens,
                new ArrayList<>(chromosomes),
                Enums.Compression.ZLIB);
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

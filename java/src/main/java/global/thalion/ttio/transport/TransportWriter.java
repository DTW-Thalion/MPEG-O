/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.codecs.BasePack;
import global.thalion.ttio.codecs.Rans;
import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

import java.io.IOException;
import java.io.OutputStream;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Serialises an {@link SpectralDataset} as a transport byte stream.
 *
 * <p>Cross-language equivalents: Python
 * {@code ttio.transport.codec.TransportWriter}, Objective-C
 * {@code TTIOTransportWriter}.</p>
 */
public final class TransportWriter implements AutoCloseable {

    private final OutputStream out;
    private final boolean ownsStream;
    private boolean useChecksum = false;
    private boolean useCompression = false;

    public TransportWriter(OutputStream out) {
        this.out = out;
        this.ownsStream = false;
    }

    public TransportWriter(Path path) throws IOException {
        this.out = new FileOutputStream(path.toFile());
        this.ownsStream = true;
    }

    public void setUseChecksum(boolean v) { this.useChecksum = v; }
    public void setUseCompression(boolean v) { this.useCompression = v; }
    public boolean useCompression() { return useCompression; }

    @Override
    public void close() throws IOException {
        if (ownsStream) out.close();
    }

    // ---------------------------------------------------------- primitives

    private static long nowNs() { return System.currentTimeMillis() * 1_000_000L; }

    private void emit(PacketType type, byte[] payload, int datasetId, long auSequence)
            throws IOException {
        int flags = useChecksum ? PacketHeader.FLAG_HAS_CHECKSUM : 0;
        emitRawPacket(type, flags, datasetId, auSequence, payload);
    }

    /** Emit a packet with arbitrary flag bits. Used by
     *  {@link global.thalion.ttio.protection.EncryptedTransport} so it
     *  can set FLAG_ENCRYPTED / FLAG_ENCRYPTED_HEADER on AUs.
     *
     *  @since 1.0
     */
    public void emitRawPacket(PacketType type, int flags, int datasetId,
                                long auSequence, byte[] payload) throws IOException {
        int finalFlags = useChecksum
            ? (flags | PacketHeader.FLAG_HAS_CHECKSUM)
            : flags;
        PacketHeader h = new PacketHeader(type, finalFlags, datasetId, auSequence,
                payload.length, nowNs());
        out.write(h.encode());
        out.write(payload);
        if (useChecksum) {
            int crc = Crc32c.compute(payload);
            ByteBuffer crcBuf = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN);
            crcBuf.putInt(crc);
            out.write(crcBuf.array());
        }
    }

    private static void appendLEString(ByteBuffer buf, String s, int width) {
        byte[] b = s == null
                ? new byte[0]
                : s.getBytes(StandardCharsets.UTF_8);
        if (width == 2) buf.putShort((short) (b.length & 0xFFFF));
        else            buf.putInt(b.length);
        buf.put(b);
    }

    private static int sizeLEString(String s, int width) {
        int b = s == null ? 0 : s.getBytes(StandardCharsets.UTF_8).length;
        return width + b;
    }

    // ---------------------------------------------------------- packets

    public void writeStreamHeader(String formatVersion, String title,
                                    String isaInvestigation, List<String> features,
                                    int nDatasets) throws IOException {
        int size = sizeLEString(formatVersion, 2)
                 + sizeLEString(title, 2)
                 + sizeLEString(isaInvestigation, 2)
                 + 2;
        for (String f : features) size += sizeLEString(f, 2);
        size += 2;
        ByteBuffer buf = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        appendLEString(buf, formatVersion, 2);
        appendLEString(buf, title, 2);
        appendLEString(buf, isaInvestigation, 2);
        buf.putShort((short) (features.size() & 0xFFFF));
        for (String f : features) appendLEString(buf, f, 2);
        buf.putShort((short) (nDatasets & 0xFFFF));
        emit(PacketType.STREAM_HEADER, buf.array(), 0, 0);
    }

    public void writeDatasetHeader(int datasetId, String name, int acquisitionMode,
                                     String spectrumClass, List<String> channelNames,
                                     String instrumentJSON, long expectedAUCount)
            throws IOException {
        int size = 2
                 + sizeLEString(name, 2)
                 + 1
                 + sizeLEString(spectrumClass, 2)
                 + 1;
        for (String c : channelNames) size += sizeLEString(c, 2);
        size += sizeLEString(instrumentJSON, 4) + 4;
        ByteBuffer buf = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        buf.putShort((short) (datasetId & 0xFFFF));
        appendLEString(buf, name, 2);
        buf.put((byte) (acquisitionMode & 0xFF));
        appendLEString(buf, spectrumClass, 2);
        buf.put((byte) (channelNames.size() & 0xFF));
        for (String c : channelNames) appendLEString(buf, c, 2);
        appendLEString(buf, instrumentJSON, 4);
        buf.putInt((int) (expectedAUCount & 0xFFFFFFFFL));
        emit(PacketType.DATASET_HEADER, buf.array(), datasetId, 0);
    }

    public void writeAccessUnit(int datasetId, long auSequence, AccessUnit au)
            throws IOException {
        emit(PacketType.ACCESS_UNIT, au.encode(), datasetId, auSequence);
    }

    public void writeEndOfDataset(int datasetId, long finalAUSequence) throws IOException {
        ByteBuffer buf = ByteBuffer.allocate(6).order(ByteOrder.LITTLE_ENDIAN);
        buf.putShort((short) (datasetId & 0xFFFF));
        buf.putInt((int) (finalAUSequence & 0xFFFFFFFFL));
        emit(PacketType.END_OF_DATASET, buf.array(), datasetId, 0);
    }

    public void writeEndOfStream() throws IOException {
        emit(PacketType.END_OF_STREAM, new byte[0], 0, 0);
    }

    // ---------------------------------------------------------- high-level

    public void writeDataset(SpectralDataset dataset) throws IOException {
        Map<String, AcquisitionRun> runs = dataset.msRuns();
        Map<String, GenomicRun> genomicRuns = dataset.genomicRuns();
        List<String> features = new ArrayList<>();
        for (String f : dataset.featureFlags().features()) features.add(f);

        writeStreamHeader("1.2", dataset.title(), dataset.isaInvestigationId(),
                features, runs.size() + genomicRuns.size());

        // Spectral dataset headers: ids 1..N.
        int id = 1;
        for (Map.Entry<String, AcquisitionRun> e : runs.entrySet()) {
            AcquisitionRun run = e.getValue();
            List<String> channelNames = new ArrayList<>(run.channels().keySet());
            String instrumentJSON = instrumentConfigJson(run.instrumentConfig());
            writeDatasetHeader(id, e.getKey(),
                    run.acquisitionMode().ordinal(),
                    run.spectrumClassName(),
                    channelNames,
                    instrumentJSON,
                    run.spectrumCount());
            id++;
        }

        // M89.2/M89.4: Genomic dataset headers: ids N+1..N+M (contiguous).
        // M90.9: now lists 5 channels (sequences, qualities + the 3
        // per-AU compound strings cigar/read_name/mate_chromosome).
        for (Map.Entry<String, GenomicRun> e : genomicRuns.entrySet()) {
            GenomicRun grun = e.getValue();
            writeDatasetHeader(id, e.getKey(),
                    grun.acquisitionMode().ordinal(),
                    "TTIOGenomicRead",
                    List.of("sequences", "qualities",
                            "cigar", "read_name", "mate_chromosome"),
                    genomicRunMetadataJson(grun),
                    grun.readCount());
            id++;
        }

        // Spectral AUs first.
        id = 1;
        for (Map.Entry<String, AcquisitionRun> e : runs.entrySet()) {
            AcquisitionRun run = e.getValue();
            int n = run.spectrumCount();
            List<String> channelNames = new ArrayList<>(run.channels().keySet());
            for (int i = 0; i < n; i++) {
                AccessUnit au = spectrumToAccessUnit(run, i, channelNames, useCompression);
                writeAccessUnit(id, i, au);
            }
            writeEndOfDataset(id, n);
            id++;
        }

        // M89.2: Then genomic AUs.
        for (Map.Entry<String, GenomicRun> e : genomicRuns.entrySet()) {
            emitGenomicRunAccessUnits(id, e.getValue());
            writeEndOfDataset(id, e.getValue().readCount());
            id++;
        }
        writeEndOfStream();
    }

    /** M89.2: Write a single {@link GenomicRun} as a stream segment.
     *
     *  <p>Used by callers that drive emission manually (multiplexed
     *  streams, M89.4). The dataset header + AUs + end-of-dataset are
     *  emitted; the caller is responsible for stream framing
     *  (writeStreamHeader / writeEndOfStream).</p>
     *
     *  @since 0.11 (M89.2)
     */
    public void writeGenomicRun(int datasetId, String name, GenomicRun run)
            throws IOException {
        writeDatasetHeader(datasetId, name,
                run.acquisitionMode().ordinal(),
                "TTIOGenomicRead",
                List.of("sequences", "qualities",
                        "cigar", "read_name", "mate_chromosome"),
                genomicRunMetadataJson(run),
                run.readCount());
        emitGenomicRunAccessUnits(datasetId, run);
        writeEndOfDataset(datasetId, run.readCount());
    }

    /** M89.2/M90.9: emit one ACCESS_UNIT packet per AlignedRead in
     *  {@code run}.
     *
     *  <p>M89.2: per-read fixed fields go into the AU's genomic suffix
     *  (chromosome / position / mapping_quality / flags). The
     *  variable-length sequences and qualities ride as two UINT8
     *  channels with the per-read slice as data.</p>
     *
     *  <p>M90.9: compound fields now also round-trip on the wire.
     *  cigar, read_name, mate_chromosome ride as additional UINT8
     *  string channels (one per AU). mate_position + template_length
     *  live in the M90.9 mate extension at the end of the AU genomic
     *  suffix.</p>
     *
     *  <p>M90.10: when the source channel carries an {@code @compression}
     *  attribute naming an M86 codec (RANS_ORDER0/1, BASE_PACK), the
     *  writer re-encodes each per-AU slice with the same codec on
     *  the wire. The wire ChannelData.compression byte tells the
     *  reader which decoder to dispatch. The 3 string channels
     *  (cigar / read_name / mate_chromosome) ALWAYS ride uncompressed —
     *  per-AU codec framing dominates short strings.</p>
     */
    private void emitGenomicRunAccessUnits(int datasetId, GenomicRun run)
            throws IOException {
        int n = run.readCount();
        int precisionUint8 = Enums.Precision.UINT8.ordinal();
        int compressionNone = Enums.Compression.NONE.ordinal();
        int acqMode = run.acquisitionMode().ordinal() & 0xFF;
        // M90.10: probe source @compression on sequences + qualities
        // so the wire codec mirrors the file's codec choice. The
        // string channels (cigar/read_name/mate_chromosome) always
        // ride uncompressed.
        int seqCodec = run.signalChannelCompressionCode("sequences");
        int qualCodec = run.signalChannelCompressionCode("qualities");
        for (int i = 0; i < n; i++) {
            AlignedRead read = run.objectAtIndex(i);
            byte[] seqBytes = read.sequence().getBytes(StandardCharsets.UTF_8);
            byte[] qualBytes = read.qualities();
            int length = seqBytes.length;
            // M90.10: re-encode per-AU slice with the M86 codec when
            // the source channel had an @compression attribute set.
            byte[] seqPayload = applyWireCodec(seqBytes, seqCodec);
            byte[] qualPayload = applyWireCodec(qualBytes, qualCodec);
            byte[] cigarBytes = (read.cigar() == null ? "" : read.cigar())
                .getBytes(StandardCharsets.UTF_8);
            byte[] nameBytes = (read.readName() == null ? "" : read.readName())
                .getBytes(StandardCharsets.UTF_8);
            byte[] mateChrBytes = (read.mateChromosome() == null ? ""
                    : read.mateChromosome()).getBytes(StandardCharsets.UTF_8);
            List<ChannelData> channels = new ArrayList<>(5);
            channels.add(new ChannelData("sequences", precisionUint8,
                    seqCodec, length, seqPayload));
            channels.add(new ChannelData("qualities", precisionUint8,
                    qualCodec, qualBytes.length, qualPayload));
            channels.add(new ChannelData("cigar", precisionUint8,
                    compressionNone, cigarBytes.length, cigarBytes));
            channels.add(new ChannelData("read_name", precisionUint8,
                    compressionNone, nameBytes.length, nameBytes));
            channels.add(new ChannelData("mate_chromosome", precisionUint8,
                    compressionNone, mateChrBytes.length, mateChrBytes));
            AccessUnit au = new AccessUnit(
                    5,                  // spectrum_class GenomicRead
                    acqMode,
                    0,                  // ms_level
                    2,                  // polarity = unknown (wire)
                    0.0, 0.0, 0,        // rt, precursor_mz, precursor_charge
                    0.0, 0.0,           // ion_mobility, base_peak_intensity
                    channels,
                    0L, 0L, 0L,         // pixel_x/y/z (unused for class==5)
                    read.chromosome(),
                    read.position(),
                    read.mappingQuality(),
                    read.flags() & 0xFFFF,
                    read.matePosition(),
                    read.templateLength());
            writeAccessUnit(datasetId, i, au);
        }
    }

    /** M90.10: encode {@code plaintext} with the given wire codec id.
     *  NONE → identity. Other ids dispatch to the matching M86 codec.
     *  Mirrors Python {@code _apply_wire_codec}. */
    private static byte[] applyWireCodec(byte[] plaintext, int codecId) {
        if (codecId == 0) return plaintext;  // NONE
        if (codecId == Enums.Compression.RANS_ORDER0.ordinal()) {
            return Rans.encode(plaintext, 0);
        }
        if (codecId == Enums.Compression.RANS_ORDER1.ordinal()) {
            return Rans.encode(plaintext, 1);
        }
        if (codecId == Enums.Compression.BASE_PACK.ordinal()) {
            return BasePack.encode(plaintext);
        }
        throw new UnsupportedOperationException(
            "applyWireCodec: codec id " + codecId
            + " not supported for genomic UINT8");
    }

    /** M89.2: Per-genomic-run metadata serialised into the
     *  {@code instrument_json} slot of the dataset header. Mirrors
     *  Python {@code _genomic_run_metadata_json}: JSON object with
     *  reference_uri, platform, sample_name, modality, sort_keys=true.
     */
    static String genomicRunMetadataJson(GenomicRun run) {
        StringBuilder sb = new StringBuilder(96);
        sb.append('{');
        appendJsonField(sb, "modality",      nz(run.modality()),     false);
        appendJsonField(sb, "platform",      nz(run.platform()),     true);
        appendJsonField(sb, "reference_uri", nz(run.referenceUri()), true);
        appendJsonField(sb, "sample_name",   nz(run.sampleName()),   true);
        sb.append('}');
        return sb.toString();
    }

    private static String nz(String s) { return s == null ? "" : s; }

    private static void appendJsonField(StringBuilder sb, String key,
                                          String value, boolean needsComma) {
        if (needsComma) sb.append(", ");
        sb.append('"').append(key).append("\": \"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == '"' || c == '\\') sb.append('\\').append(c);
            else sb.append(c);
        }
        sb.append('"');
    }

    static String instrumentConfigJson(InstrumentConfig cfg) {
        if (cfg == null) return "{}";
        // Minimal sorted-key JSON emitter to match Python / ObjC output
        // without pulling a full JSON library in.
        StringBuilder sb = new StringBuilder(128);
        sb.append('{');
        appendField(sb, "analyzer_type", cfg.analyzerType(), false);
        appendField(sb, "detector_type", cfg.detectorType(), true);
        appendField(sb, "manufacturer",  cfg.manufacturer(),  true);
        appendField(sb, "model",         cfg.model(),         true);
        appendField(sb, "serial_number", cfg.serialNumber(),  true);
        appendField(sb, "source_type",   cfg.sourceType(),    true);
        sb.append('}');
        return sb.toString();
    }

    private static void appendField(StringBuilder sb, String key, String value,
                                      boolean needsComma) {
        if (needsComma) sb.append(", ");
        sb.append('"').append(key).append("\": \"");
        String v = value == null ? "" : value;
        for (int i = 0; i < v.length(); i++) {
            char c = v.charAt(i);
            if (c == '"' || c == '\\') sb.append('\\').append(c);
            else sb.append(c);
        }
        sb.append('"');
    }

    static AccessUnit spectrumToAccessUnit(AcquisitionRun run, int i,
                                              List<String> channelNames) {
        return spectrumToAccessUnit(run, i, channelNames, false);
    }

    static AccessUnit spectrumToAccessUnit(AcquisitionRun run, int i,
                                              List<String> channelNames,
                                              boolean useCompression) {
        Spectrum sp = run.objectAtIndex(i);
        int wireClass = wireFromSpectrumClassName(run.spectrumClassName());
        int msLevel = 0;
        int polarityWire = 2;
        if (sp instanceof MassSpectrum ms) {
            msLevel = ms.msLevel();
            polarityWire = wireFromPolarity(ms.polarity());
        }

        double bpi = 0.0;
        SpectrumIndex idx = run.spectrumIndex();
        if (idx != null && i < idx.count()) {
            bpi = idx.basePeakIntensities()[i];
        }

        List<ChannelData> channels = new ArrayList<>();
        double[] all;
        for (String cname : channelNames) {
            all = run.channels().get(cname);
            if (all == null) continue;
            int off = (int) idx.offsetAt(i);
            int len = idx.lengthAt(i);
            byte[] raw = new byte[len * 8];
            ByteBuffer buf = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
            for (int k = 0; k < len; k++) buf.putDouble(all[off + k]);
            byte[] payload = raw;
            int compressionCode = Enums.Compression.NONE.ordinal();
            if (useCompression) {
                payload = zlibDeflate(raw);
                compressionCode = Enums.Compression.ZLIB.ordinal();
            }
            channels.add(new ChannelData(cname,
                    Enums.Precision.FLOAT64.ordinal(),
                    compressionCode,
                    len, payload));
        }

        return new AccessUnit(
                wireClass,
                run.acquisitionMode().ordinal(),
                msLevel,
                polarityWire,
                sp.scanTimeSeconds(),
                sp.precursorMz(),
                sp.precursorCharge(),
                0.0,
                bpi,
                channels,
                0, 0, 0);
    }

    private static byte[] zlibDeflate(byte[] input) {
        java.util.zip.Deflater def = new java.util.zip.Deflater();
        def.setInput(input);
        def.finish();
        byte[] buf = new byte[Math.max(64, input.length)];
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        while (!def.finished()) {
            int n = def.deflate(buf);
            out.write(buf, 0, n);
        }
        def.end();
        return out.toByteArray();
    }

    private static int wireFromSpectrumClassName(String name) {
        if (name == null) return 0;
        return switch (name) {
            case "TTIOMassSpectrum"       -> 0;
            case "TTIONMRSpectrum"        -> 1;
            case "TTIONMR2DSpectrum"      -> 2;
            case "TTIOFreeInductionDecay" -> 3;
            case "TTIOMSImagePixel"       -> 4;
            default -> 0;
        };
    }

    private static int wireFromPolarity(Enums.Polarity p) {
        return switch (p) {
            case POSITIVE -> 0;
            case NEGATIVE -> 1;
            case UNKNOWN  -> 2;
        };
    }
}

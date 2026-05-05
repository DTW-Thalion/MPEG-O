/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package global.thalion.ttio.protection;

import global.thalion.ttio.Enums;
import global.thalion.ttio.FeatureFlags;
import global.thalion.ttio.protection.PerAUEncryption.ChannelSegment;
import global.thalion.ttio.protection.PerAUEncryption.HeaderSegment;
import global.thalion.ttio.providers.CompoundField;
import global.thalion.ttio.providers.ProviderRegistry;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;
import global.thalion.ttio.providers.StorageProvider;
import global.thalion.ttio.transport.PacketHeader;
import global.thalion.ttio.transport.PacketType;
import global.thalion.ttio.transport.TransportReader;
import global.thalion.ttio.transport.TransportWriter;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

/**
 * v1.0 transport layer for per-AU encrypted files. Writer pushes
 * ciphertext bytes from the {@code <channel>_segments} compound onto
 * the wire unmodified (the server never decrypts in transit, per
 * {@code docs/transport-spec.md} §6.2). Reader materialises an
 * encrypted {@code .tio} on the receiver side preserving ciphertext
 * bytes verbatim.
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.transport.encrypted}, Objective-C
 * {@code TTIOEncryptedTransport}.
 *
 *
 */
public final class EncryptedTransport {

    private EncryptedTransport() {}

    // ────────────────────────────────────────────────────────── probe

    /** {@code true} iff the file at {@code path} carries
     *  {@code opt_per_au_encryption}. */
    public static boolean isPerAUEncrypted(String path, String providerName) {
        StorageProvider sp = ProviderRegistry.open(path,
            StorageProvider.Mode.READ, providerName);
        try {
            StorageGroup root = sp.rootGroup();
            FeatureFlags flags = FeatureFlags.readFrom(root);
            return flags.has(FeatureFlags.OPT_PER_AU_ENCRYPTION);
        } finally {
            sp.close();
        }
    }

    // ────────────────────────────────────────────────────────── writer

    /** Emit the full transport stream from a per-AU-encrypted file.
     *
     *  <p>M90.8: also walks {@code /study/genomic_runs/} after MS runs.
     *  Genomic dataset_id continues from MS (1..N MS, N+1..N+M genomic)
     *  so AAD reconstruction matches the per-AU encrypt path
     *  (M90.1).</p> */
    public static void writeEncryptedDataset(String ttioPath,
                                               TransportWriter writer,
                                               String providerName)
            throws IOException {
        StorageProvider sp = ProviderRegistry.open(ttioPath,
            StorageProvider.Mode.READ, providerName);
        try {
            StorageGroup root = sp.rootGroup();
            FeatureFlags flags = FeatureFlags.readFrom(root);
            if (!flags.has(FeatureFlags.OPT_PER_AU_ENCRYPTION)) {
                throw new IllegalStateException(
                    ttioPath + " does not carry opt_per_au_encryption");
            }
            boolean headersEncrypted = flags.has(FeatureFlags.OPT_ENCRYPTED_AU_HEADERS);

            try (StorageGroup study = root.openGroup("study")) {
                String title = attrStr(study, "title", "");
                String isa = attrStr(study, "isa_investigation_id", "");

                List<String> msRunNames = new ArrayList<>();
                if (study.hasChild("ms_runs")) {
                    try (StorageGroup msRuns = study.openGroup("ms_runs")) {
                        for (String n : msRuns.childNames()) {
                            if (!n.startsWith("_") && msRuns.hasChild(n)) {
                                msRunNames.add(n);
                            }
                        }
                    }
                }
                List<String> genomicRunNames = new ArrayList<>();
                if (study.hasChild("genomic_runs")) {
                    try (StorageGroup gRuns = study.openGroup("genomic_runs")) {
                        for (String n : gRuns.childNames()) {
                            if (!n.startsWith("_") && gRuns.hasChild(n)) {
                                genomicRunNames.add(n);
                            }
                        }
                    }
                }

                List<String> features = new ArrayList<>(flags.features());
                writer.writeStreamHeader("1.2", title, isa, features,
                                          msRunNames.size() + genomicRunNames.size());
                int did = 1;
                if (!msRunNames.isEmpty()) {
                    try (StorageGroup msRuns = study.openGroup("ms_runs")) {
                        for (String runName : msRunNames) {
                            try (StorageGroup run = msRuns.openGroup(runName);
                                 StorageGroup sig = run.openGroup("signal_channels")) {
                                List<String> channelNames = splitNames(
                                    attrStr(sig, "channel_names", ""));
                                String firstCh = channelNames.isEmpty()
                                    ? "intensity" : channelNames.get(0);
                                String cipherSuite = attrStr(sig,
                                    firstCh + "_algorithm", "aes-256-gcm");
                                String kek = attrStr(sig,
                                    firstCh + "_kek_algorithm", "");
                                byte[] wrapped = attrBytes(sig,
                                    firstCh + "_wrapped_dek");

                                writer.emitRawPacket(PacketType.PROTECTION_METADATA, 0,
                                    did, 0, encodeProtection(cipherSuite, kek, wrapped));

                                long expectedAUs = firstChannelSegmentCount(sig, firstCh);
                                int acqMode = intAttr(run, "acquisition_mode", 0);
                                String spectrumClass = attrStr(run, "spectrum_class",
                                                                 "TTIOMassSpectrum");
                                writer.writeDatasetHeader(did, runName, acqMode,
                                    spectrumClass, channelNames, "{}", expectedAUs);
                            }
                            did++;
                        }

                        did = 1;
                        for (String runName : msRunNames) {
                            long n = emitRunAUs(writer, msRuns, runName, did,
                                                  headersEncrypted);
                            writer.writeEndOfDataset(did, n);
                            did++;
                        }
                    }
                }

                if (!genomicRunNames.isEmpty()) {
                    try (StorageGroup gRuns = study.openGroup("genomic_runs")) {
                        int firstGenomicDid = did;
                        for (String runName : genomicRunNames) {
                            emitGenomicDatasetHeader(writer, gRuns, runName, did);
                            did++;
                        }
                        did = firstGenomicDid;
                        for (String runName : genomicRunNames) {
                            long n = emitGenomicRunAUs(writer, gRuns, runName, did);
                            writer.writeEndOfDataset(did, n);
                            did++;
                        }
                    }
                }
            }
            writer.writeEndOfStream();
        } finally {
            sp.close();
        }
    }

    /** M90.8: emit ProtectionMetadata + DatasetHeader for one genomic
     *  run. Genomic only encrypts {@code sequences} + {@code qualities}
     *  (per M90.1); other channels (cigars, read_names, mate_info)
     *  stay plaintext on the source file and are not part of the
     *  encrypted-transport contract. */
    private static void emitGenomicDatasetHeader(TransportWriter writer,
                                                   StorageGroup gRuns,
                                                   String runName,
                                                   int datasetId)
            throws IOException {
        try (StorageGroup run = gRuns.openGroup(runName);
             StorageGroup sig = run.openGroup("signal_channels")) {
            List<String> channelNames = new ArrayList<>(2);
            for (String c : new String[]{"sequences", "qualities"}) {
                if (sig.hasChild(c + "_segments")) channelNames.add(c);
            }
            String firstCh = channelNames.isEmpty()
                ? "sequences" : channelNames.get(0);
            String cipherSuite = attrStr(sig,
                firstCh + "_algorithm", "aes-256-gcm");
            String kek = attrStr(sig, firstCh + "_kek_algorithm", "");
            byte[] wrapped = attrBytes(sig, firstCh + "_wrapped_dek");
            writer.emitRawPacket(PacketType.PROTECTION_METADATA, 0,
                datasetId, 0, encodeProtection(cipherSuite, kek, wrapped));

            int acqMode = intAttr(run, "acquisition_mode", 0);
            String metadataJson = genomicRunMetadataJson(
                attrStr(run, "modality", ""),
                attrStr(run, "platform", ""),
                attrStr(run, "reference_uri", ""),
                attrStr(run, "sample_name", ""));
            long expectedAUs = channelNames.isEmpty()
                ? 0L
                : PerAUFile.readChannelSegments(sig,
                      channelNames.get(0) + "_segments").size();
            writer.writeDatasetHeader(datasetId, runName, acqMode,
                "TTIOGenomicRead", channelNames, metadataJson, expectedAUs);
        }
    }

    /** M90.8: emit one ENCRYPTED ACCESS_UNIT packet per read.
     *  Each AU carries {@code spectrum_class=5}, the M89.1 chromosome
     *  + position + mapq + flags suffix (sourced from the plaintext
     *  {@code genomic_index/}), and UINT8 ChannelData with
     *  {@code IV || TAG || ciphertext} for each encrypted channel. */
    private static long emitGenomicRunAUs(TransportWriter writer,
                                            StorageGroup gRuns,
                                            String runName,
                                            int datasetId)
            throws IOException {
        try (StorageGroup run = gRuns.openGroup(runName);
             StorageGroup sig = run.openGroup("signal_channels");
             StorageGroup idx = run.openGroup("genomic_index")) {
            List<String> channelNames = new ArrayList<>(2);
            for (String c : new String[]{"sequences", "qualities"}) {
                if (sig.hasChild(c + "_segments")) channelNames.add(c);
            }
            int acqMode = intAttr(run, "acquisition_mode", 0);
            Map<String, List<ChannelSegment>> segsByCh = new LinkedHashMap<>();
            for (String c : channelNames) {
                segsByCh.put(c, PerAUFile.readChannelSegments(sig, c + "_segments"));
            }
            long[] positions;
            byte[] mapqs;
            int[] flagsArr;
            try (StorageDataset d = idx.openDataset("positions")) {
                positions = (long[]) d.readAll();
            }
            try (StorageDataset d = idx.openDataset("mapping_qualities")) {
                mapqs = (byte[]) d.readAll();
            }
            try (StorageDataset d = idx.openDataset("flags")) {
                flagsArr = (int[]) d.readAll();
            }
            List<String> chromosomes = readGenomicChromosomes(idx);
            int n = channelNames.isEmpty() ? 0 : segsByCh.get(channelNames.get(0)).size();
            int uint8Precision = global.thalion.ttio.Enums.Precision.UINT8.ordinal();

            for (int i = 0; i < n; i++) {
                List<global.thalion.ttio.transport.ChannelData> channels =
                    new ArrayList<>(channelNames.size());
                for (String c : channelNames) {
                    ChannelSegment seg = segsByCh.get(c).get(i);
                    byte[] data = concat(seg.iv(), seg.tag(), seg.ciphertext());
                    channels.add(new global.thalion.ttio.transport.ChannelData(
                        c, uint8Precision, 0, seg.length(), data));
                }
                global.thalion.ttio.transport.AccessUnit au =
                    new global.thalion.ttio.transport.AccessUnit(
                        5, acqMode, 0, 2,
                        0.0, 0.0, 0,
                        0.0, 0.0,
                        channels,
                        0L, 0L, 0L,
                        chromosomes.get(i),
                        positions[i],
                        mapqs[i] & 0xFF,
                        flagsArr[i] & 0xFFFF);
                writer.emitRawPacket(PacketType.ACCESS_UNIT,
                    PacketHeader.FLAG_ENCRYPTED, datasetId, i, au.encode());
            }
            return n;
        }
    }

    @SuppressWarnings("unchecked")
    private static List<String> readGenomicChromosomes(StorageGroup idx) {
        // L1 (Task #82 Phase B.1): chromosomes are stored as
        // chromosome_ids (uint16) + chromosome_names (compound).
        short[] ids;
        try (StorageDataset ds = idx.openDataset("chromosome_ids")) {
            ids = (short[]) ds.readAll();
        }
        List<Object[]> nameRows;
        try (StorageDataset ds = idx.openDataset("chromosome_names")) {
            nameRows = (List<Object[]>) ds.readAll();
        }
        List<String> nameTable = new ArrayList<>(nameRows.size());
        for (Object[] r : nameRows) {
            Object v = r[0];
            if (v == null) nameTable.add("");
            else if (v instanceof byte[] b) nameTable.add(new String(b, StandardCharsets.UTF_8));
            else nameTable.add(v.toString());
        }
        {
            List<String> out = new ArrayList<>(ids.length);
            for (short id : ids) {
                int idx2 = Short.toUnsignedInt(id);
                out.add(idx2 < nameTable.size() ? nameTable.get(idx2) : "");
            }
            return out;
        }
    }

    private static String genomicRunMetadataJson(String modality, String platform,
                                                   String referenceUri, String sampleName) {
        char QT = (char) 34;
        char OB = (char) 123;
        char CB = (char) 125;
        StringBuilder sb = new StringBuilder(96);
        sb.append(OB);
        sb.append(QT).append("modality").append(QT).append(": ").append(QT).append(esc(modality)).append(QT);
        sb.append(", ");
        sb.append(QT).append("platform").append(QT).append(": ").append(QT).append(esc(platform)).append(QT);
        sb.append(", ");
        sb.append(QT).append("reference_uri").append(QT).append(": ").append(QT).append(esc(referenceUri)).append(QT);
        sb.append(", ");
        sb.append(QT).append("sample_name").append(QT).append(": ").append(QT).append(esc(sampleName)).append(QT);
        sb.append(CB);
        return sb.toString();
    }

    private static String esc(String value) {
        if (value == null) return "";
        char QT = (char) 34;
        char BS = (char) 92;
        StringBuilder out = new StringBuilder(value.length());
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == QT || c == BS) out.append(BS);
            out.append(c);
        }
        return out.toString();
    }

    /** @return number of AU packets emitted for this run. */
    private static long emitRunAUs(TransportWriter writer, StorageGroup msRuns,
                                     String runName, int datasetId,
                                     boolean headersEncrypted) throws IOException {
        try (StorageGroup run = msRuns.openGroup(runName);
             StorageGroup sig = run.openGroup("signal_channels");
             StorageGroup idx = run.openGroup("spectrum_index")) {
        List<String> channelNames = splitNames(
            attrStr(sig, "channel_names", ""));
        int acqMode = intAttr(run, "acquisition_mode", 0);
        int wireClass = wireFromSpectrumClass(
            attrStr(run, "spectrum_class", "TTIOMassSpectrum"));

        Map<String, List<ChannelSegment>> segsByCh = new LinkedHashMap<>();
        for (String c : channelNames) {
            segsByCh.put(c, PerAUFile.readChannelSegments(sig, c + "_segments"));
        }
        List<HeaderSegment> hdrSegs = null;
        if (headersEncrypted) {
            hdrSegs = PerAUFile.readHeaderSegments(idx, "au_header_segments");
        }

        List<ChannelSegment> firstSegs = segsByCh.get(channelNames.get(0));
        int n = firstSegs.size();

        // Plaintext filter arrays (only read when headers are NOT encrypted).
        double[] rts = null, pmzs = null, bpis = null;
        int[] msLevels = null, pols = null, pcs = null;
        if (!headersEncrypted) {
            try (StorageDataset d = idx.openDataset("retention_times")) {
                rts = (double[]) d.readAll(); }
            try (StorageDataset d = idx.openDataset("ms_levels")) {
                msLevels = (int[]) d.readAll(); }
            try (StorageDataset d = idx.openDataset("polarities")) {
                pols = (int[]) d.readAll(); }
            try (StorageDataset d = idx.openDataset("precursor_mzs")) {
                pmzs = (double[]) d.readAll(); }
            try (StorageDataset d = idx.openDataset("precursor_charges")) {
                pcs = (int[]) d.readAll(); }
            try (StorageDataset d = idx.openDataset("base_peak_intensities")) {
                bpis = (double[]) d.readAll(); }
        }

        for (int i = 0; i < n; i++) {
            List<byte[]> channelPayloads = new ArrayList<>(channelNames.size());
            for (String c : channelNames) {
                ChannelSegment seg = segsByCh.get(c).get(i);
                byte[] data = concat(seg.iv(), seg.tag(), seg.ciphertext());
                channelPayloads.add(encodeChannelData(c, seg.length(), data));
            }
            int flags = PacketHeader.FLAG_ENCRYPTED;
            byte[] payload;
            if (headersEncrypted) {
                flags |= PacketHeader.FLAG_ENCRYPTED_HEADER;
                payload = encodeEncryptedHeaderAU(wireClass, channelNames.size(),
                    hdrSegs.get(i), channelPayloads);
            } else {
                int polWire = polToWire(pols[i]);
                payload = encodePlaintextHeaderAU(wireClass, acqMode, msLevels[i],
                    polWire, rts[i], pmzs[i], pcs[i], 0.0, bpis[i],
                    channelPayloads);
            }
            writer.emitRawPacket(PacketType.ACCESS_UNIT, flags, datasetId, i,
                                    payload);
        }
        return n;
        }
    }

    // ────────────────────────────────────────────────────────── reader

    /** Materialise an encrypted transport stream into {@code outputPath}. */
    public static void readEncryptedToPath(String outputPath, byte[] streamData,
                                             String providerName)
            throws IOException {
        TransportReader reader = new TransportReader(streamData);
        List<TransportReader.PacketRecord> packets = reader.readAllPackets();
        reader.close();

        String title = "";
        String isa = "";
        List<String> features = new ArrayList<>();
        Map<Integer, DatasetAccumulator> datasets = new TreeMap<>();
        Map<Integer, ProtectionMeta> protection = new TreeMap<>();

        for (TransportReader.PacketRecord rec : packets) {
            PacketType t = rec.header.packetType;
            switch (t) {
                case STREAM_HEADER -> {
                    ParsedStreamHeader h = parseStreamHeader(rec.payload);
                    title = h.title;
                    isa = h.isa;
                    features.addAll(h.features);
                }
                case PROTECTION_METADATA -> {
                    protection.put(rec.header.datasetId,
                                    parseProtection(rec.payload));
                }
                case DATASET_HEADER -> {
                    ParsedDatasetHeader h = parseDatasetHeader(rec.payload);
                    boolean isGenomic = "TTIOGenomicRead".equals(h.spectrumClass);
                    DatasetAccumulator acc = new DatasetAccumulator(
                        h.name, h.acqMode, h.spectrumClass, h.channelNames,
                        h.instrumentJson, isGenomic);
                    datasets.put(h.datasetId, acc);
                }
                case ACCESS_UNIT -> {
                    DatasetAccumulator acc = datasets.get(rec.header.datasetId);
                    if (acc == null) {
                        throw new IllegalStateException(
                            "AU for unknown dataset_id " + rec.header.datasetId);
                    }
                    ingestAU(rec.header.flags, rec.payload, acc);
                }
                default -> { /* END_OF_DATASET / END_OF_STREAM: ignore */ }
            }
        }

        TreeSet<String> featureSet = new TreeSet<>(features);
        featureSet.add(FeatureFlags.OPT_PER_AU_ENCRYPTION);
        boolean anyHeaderEnc = datasets.values().stream()
            .anyMatch(d -> d.usedEncryptedHeaders);
        if (anyHeaderEnc) featureSet.add(FeatureFlags.OPT_ENCRYPTED_AU_HEADERS);

        writeEncryptedFile(outputPath, providerName, title, isa,
                            new ArrayList<>(featureSet), protection, datasets);
    }

    // ────────────────────────────────────────────── payload encoders

    private static byte[] encodeProtection(String cipherSuite, String kek,
                                             byte[] wrapped) {
        byte[] cs = cipherSuite.getBytes(StandardCharsets.UTF_8);
        byte[] kk = kek.getBytes(StandardCharsets.UTF_8);
        int len = 2 + cs.length + 2 + kk.length + 4 + wrapped.length + 2 + 4;
        ByteBuffer buf = ByteBuffer.allocate(len).order(ByteOrder.LITTLE_ENDIAN);
        buf.putShort((short) cs.length); buf.put(cs);
        buf.putShort((short) kk.length); buf.put(kk);
        buf.putInt(wrapped.length); buf.put(wrapped);
        buf.putShort((short) 0); // signature_algorithm
        buf.putInt(0);            // public_key length
        return buf.array();
    }

    private static byte[] encodeChannelData(String cname, int nElements,
                                              byte[] data) {
        byte[] nameUtf = cname.getBytes(StandardCharsets.UTF_8);
        int len = 2 + nameUtf.length + 1 + 1 + 4 + 4 + data.length;
        ByteBuffer buf = ByteBuffer.allocate(len).order(ByteOrder.LITTLE_ENDIAN);
        buf.putShort((short) nameUtf.length); buf.put(nameUtf);
        buf.put((byte) Enums.Precision.FLOAT64.ordinal());
        buf.put((byte) Enums.Compression.NONE.ordinal());
        buf.putInt(nElements);
        buf.putInt(data.length);
        buf.put(data);
        return buf.array();
    }

    private static byte[] encodeEncryptedHeaderAU(int wireClass, int nChannels,
                                                    HeaderSegment hdrSeg,
                                                    List<byte[]> channelPayloads) {
        int total = 1 + 1 + 12 + 16 + 36;
        for (byte[] cp : channelPayloads) total += cp.length;
        ByteBuffer buf = ByteBuffer.allocate(total).order(ByteOrder.LITTLE_ENDIAN);
        buf.put((byte) wireClass);
        buf.put((byte) nChannels);
        buf.put(hdrSeg.iv());
        buf.put(hdrSeg.tag());
        buf.put(hdrSeg.ciphertext());
        for (byte[] cp : channelPayloads) buf.put(cp);
        return buf.array();
    }

    private static byte[] encodePlaintextHeaderAU(int wireClass, int acqMode,
                                                    int msLevel, int polWire,
                                                    double rt, double pmz,
                                                    int pc, double ionMob,
                                                    double bpi,
                                                    List<byte[]> channelPayloads) {
        int total = 1 + 1 + 1 + 1 + 8 + 8 + 1 + 8 + 8 + 1;
        for (byte[] cp : channelPayloads) total += cp.length;
        ByteBuffer buf = ByteBuffer.allocate(total).order(ByteOrder.LITTLE_ENDIAN);
        buf.put((byte) wireClass);
        buf.put((byte) acqMode);
        buf.put((byte) (msLevel & 0xFF));
        buf.put((byte) polWire);
        buf.putDouble(rt);
        buf.putDouble(pmz);
        buf.put((byte) (pc & 0xFF));
        buf.putDouble(ionMob);
        buf.putDouble(bpi);
        buf.put((byte) channelPayloads.size());
        for (byte[] cp : channelPayloads) buf.put(cp);
        return buf.array();
    }

    // ────────────────────────────────────────────── payload decoders

    private static final class ParsedStreamHeader {
        String title = "", isa = "";
        List<String> features = new ArrayList<>();
    }

    private static ParsedStreamHeader parseStreamHeader(byte[] payload) {
        ParsedStreamHeader out = new ParsedStreamHeader();
        ByteBuffer bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
        readLEString(bb, 2);   // format_version — ignored here
        out.title = readLEString(bb, 2);
        out.isa = readLEString(bb, 2);
        int nFeat = bb.getShort() & 0xFFFF;
        for (int i = 0; i < nFeat; i++) out.features.add(readLEString(bb, 2));
        // n_datasets follows; discovered via DATASET_HEADER packets.
        return out;
    }

    private static final class ParsedDatasetHeader {
        int datasetId;
        String name;
        int acqMode;
        String spectrumClass;
        List<String> channelNames;
        String instrumentJson = "";
    }

    private static ParsedDatasetHeader parseDatasetHeader(byte[] payload) {
        ParsedDatasetHeader out = new ParsedDatasetHeader();
        ByteBuffer bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
        out.datasetId = bb.getShort() & 0xFFFF;
        out.name = readLEString(bb, 2);
        out.acqMode = bb.get() & 0xFF;
        out.spectrumClass = readLEString(bb, 2);
        int nch = bb.get() & 0xFF;
        out.channelNames = new ArrayList<>(nch);
        for (int i = 0; i < nch; i++) out.channelNames.add(readLEString(bb, 2));
        // M90.8: instrument_json carries the genomic-run metadata for the
        // reader to rebuild modality/platform/reference_uri/sample_name.
        if (bb.remaining() >= 4) {
            out.instrumentJson = readLEString(bb, 4);
        } else {
            out.instrumentJson = "";
        }
        return out;
    }

    private static ProtectionMeta parseProtection(byte[] payload) {
        ByteBuffer bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
        String cs = readLEString(bb, 2);
        String kek = readLEString(bb, 2);
        int wLen = bb.getInt();
        byte[] wrapped = new byte[wLen];
        bb.get(wrapped);
        return new ProtectionMeta(cs, kek, wrapped);
    }

    private static void ingestAU(int flags, byte[] payload,
                                   DatasetAccumulator acc) {
        boolean encHeader = (flags & PacketHeader.FLAG_ENCRYPTED_HEADER) != 0;
        boolean encChannel = (flags & PacketHeader.FLAG_ENCRYPTED) != 0;
        if (!encChannel) {
            throw new IllegalStateException("ingestAU on plaintext AU");
        }
        acc.usedEncryptedHeaders = encHeader;
        ByteBuffer bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);

        if (encHeader) {
            bb.get();
            int nChannels = bb.get() & 0xFF;
            byte[] iv = new byte[12]; bb.get(iv);
            byte[] tag = new byte[16]; bb.get(tag);
            byte[] ct = new byte[36]; bb.get(ct);
            acc.headerSegments.add(new HeaderSegment(iv, tag, ct));
            readEncryptedChannels(bb, nChannels, acc);
            return;
        }
        bb.get();
        int acq = bb.get() & 0xFF;
        int msLevel = bb.get() & 0xFF;
        int polWire = bb.get() & 0xFF;
        double rt = bb.getDouble();
        double pmz = bb.getDouble();
        int pc = bb.get() & 0xFF;
        double ionMob = bb.getDouble();
        double bpi = bb.getDouble();
        int nChannels = bb.get() & 0xFF;
        if (acc.acquisitionMode == 0) acc.acquisitionMode = acq;
        if (acc.isGenomic) {
            readEncryptedChannels(bb, nChannels, acc);
            global.thalion.ttio.transport.AccessUnit au =
                global.thalion.ttio.transport.AccessUnit.decode(payload);
            acc.genomicChromosomes.add(au.chromosome);
            acc.genomicPositions.add(au.position);
            acc.genomicMapqs.add(au.mappingQuality);
            acc.genomicFlags.add(au.flags & 0xFFFFFFFFL);
        } else {
            acc.plaintextRts.add(rt);
            acc.plaintextMsLevels.add(msLevel);
            int polInt = 0;
            if (polWire == 0) polInt = 1;
            else if (polWire == 1) polInt = -1;
            acc.plaintextPolarities.add(polInt);
            acc.plaintextPmzs.add(pmz);
            acc.plaintextPcs.add(pc);
            acc.plaintextBpis.add(bpi);
            readEncryptedChannels(bb, nChannels, acc);
        }
        @SuppressWarnings("unused") double _im = ionMob;
    }

    private static void readEncryptedChannels(ByteBuffer bb, int nChannels,
                                                 DatasetAccumulator acc) {
        for (int c = 0; c < nChannels; c++) {
            int nameLen = bb.getShort() & 0xFFFF;
            byte[] nameBytes = new byte[nameLen];
            bb.get(nameBytes);
            String cname = new String(nameBytes, StandardCharsets.UTF_8);
            bb.get();                           // precision
            bb.get();                           // compression
            int nElements = bb.getInt();
            int dataLen = bb.getInt();
            if (dataLen < 28) {
                throw new IllegalStateException(
                    "encrypted channel data shorter than IV+TAG");
            }
            byte[] iv = new byte[12]; bb.get(iv);
            byte[] tag = new byte[16]; bb.get(tag);
            byte[] ct = new byte[dataLen - 28]; bb.get(ct);

            List<ChannelSegment> segs = acc.channelSegments
                .computeIfAbsent(cname, k -> new ArrayList<>());
            if (!acc.channelNames.contains(cname)) acc.channelNames.add(cname);
            long prior = 0;
            for (ChannelSegment s : segs) prior += s.length();
            segs.add(new ChannelSegment(prior, nElements, iv, tag, ct));
        }
    }

    // ──────────────────────────────────────────── file materialisation

    private static void writeEncryptedFile(String path, String providerName,
                                             String title, String isa,
                                             List<String> features,
                                             Map<Integer, ProtectionMeta> protection,
                                             Map<Integer, DatasetAccumulator> datasets) {
        StorageProvider sp = ProviderRegistry.open(path,
            StorageProvider.Mode.CREATE, providerName);
        try {
            StorageGroup root = sp.rootGroup();
            // M90.8: bump format_version to 1.4 + add opt_genomic when any
            // genomic dataset came through the stream (matches the
            // SpectralDataset.create heuristic).
            boolean anyGenomic = false;
            for (DatasetAccumulator d : datasets.values()) {
                if (d.isGenomic) { anyGenomic = true; break; }
            }
            String formatVersion = anyGenomic ? "1.4" : "1.1";
            List<String> writtenFeatures = new ArrayList<>(features);
            if (anyGenomic && !writtenFeatures.contains(FeatureFlags.OPT_GENOMIC)) {
                writtenFeatures.add(FeatureFlags.OPT_GENOMIC);
                java.util.Collections.sort(writtenFeatures);
            }
            new FeatureFlags(formatVersion, writtenFeatures).writeTo(root);

            try (StorageGroup study = root.createGroup("study")) {
                study.setAttribute("title", title == null ? "" : title);
                study.setAttribute("isa_investigation_id",
                                     isa == null ? "" : isa);

                // M90.8: split datasets into MS vs genomic.
                Map<Integer, DatasetAccumulator> msDs = new TreeMap<>();
                Map<Integer, DatasetAccumulator> gDs = new TreeMap<>();
                for (Map.Entry<Integer, DatasetAccumulator> e : datasets.entrySet()) {
                    if (e.getValue().isGenomic) gDs.put(e.getKey(), e.getValue());
                    else msDs.put(e.getKey(), e.getValue());
                }

                if (!msDs.isEmpty()) {
                    try (StorageGroup msRuns = study.createGroup("ms_runs")) {
                        StringBuilder names = new StringBuilder();
                        boolean first = true;
                        for (DatasetAccumulator acc : msDs.values()) {
                            if (!first) names.append(',');
                            names.append(acc.name);
                            first = false;
                        }
                        msRuns.setAttribute("_run_names", names.toString());
                        for (Map.Entry<Integer, DatasetAccumulator> e : msDs.entrySet()) {
                            materialiseRun(msRuns, e.getValue(), protection.get(e.getKey()));
                        }
                    }
                }

                if (!gDs.isEmpty()) {
                    try (StorageGroup gRuns = study.createGroup("genomic_runs")) {
                        StringBuilder gnames = new StringBuilder();
                        boolean first = true;
                        for (DatasetAccumulator acc : gDs.values()) {
                            if (!first) gnames.append(',');
                            gnames.append(acc.name);
                            first = false;
                        }
                        gRuns.setAttribute("_run_names", gnames.toString());
                        for (Map.Entry<Integer, DatasetAccumulator> e : gDs.entrySet()) {
                            materialiseGenomicRun(gRuns, e.getValue(), protection.get(e.getKey()));
                        }
                    }
                }
            }
        } finally {
            sp.close();
        }
    }

    private static void materialiseRun(StorageGroup msRuns,
                                         DatasetAccumulator acc,
                                         ProtectionMeta pm) {
        try (StorageGroup run = msRuns.createGroup(acc.name)) {
        run.setAttribute("acquisition_mode", (long) acc.acquisitionMode);
        run.setAttribute("spectrum_class",
                          acc.spectrumClass == null
                            ? "TTIOMassSpectrum" : acc.spectrumClass);
        int spectrumCount = acc.headerSegments.isEmpty()
            ? acc.channelSegments.get(acc.channelNames.get(0)).size()
            : acc.headerSegments.size();
        run.setAttribute("spectrum_count", (long) spectrumCount);

        try (StorageGroup cfg = run.createGroup("instrument_config")) {
            for (String f : new String[]{"manufacturer", "model", "serial_number",
                                           "source_type", "analyzer_type",
                                           "detector_type"}) {
                cfg.setAttribute(f, "");
            }
        }

        try (StorageGroup sig = run.createGroup("signal_channels")) {
        sig.setAttribute("channel_names", String.join(",", acc.channelNames));
        for (String cname : acc.channelNames) {
            List<ChannelSegment> segs = acc.channelSegments.get(cname);
            PerAUFile.writeChannelSegments(sig, cname + "_segments", segs);
            sig.setAttribute(cname + "_algorithm",
                pm != null && pm.cipherSuite != null
                    ? pm.cipherSuite : "aes-256-gcm");
            if (pm != null && pm.wrappedDek != null && pm.wrappedDek.length > 0) {
                sig.setAttribute(cname + "_wrapped_dek", pm.wrappedDek);
                sig.setAttribute(cname + "_kek_algorithm",
                                  pm.kekAlgorithm == null ? "" : pm.kekAlgorithm);
            }
        }

        try (StorageGroup idx = run.createGroup("spectrum_index")) {
            List<ChannelSegment> firstSegs = acc.channelSegments.get(acc.channelNames.get(0));
            idx.setAttribute("count", (long) firstSegs.size());
            writePrimitiveArray(idx, "offsets", Enums.Precision.INT64,
                firstSegs.stream().mapToLong(ChannelSegment::offset).toArray());
            writePrimitiveArray(idx, "lengths", Enums.Precision.UINT32,
                firstSegs.stream().mapToInt(ChannelSegment::length).toArray());

            if (acc.usedEncryptedHeaders) {
                PerAUFile.writeHeaderSegments(idx, "au_header_segments",
                                                 acc.headerSegments);
            } else {
                writePrimitiveArray(idx, "retention_times",
                    Enums.Precision.FLOAT64, toDoubleArr(acc.plaintextRts));
                writePrimitiveArray(idx, "ms_levels",
                    Enums.Precision.INT32, toIntArr(acc.plaintextMsLevels));
                writePrimitiveArray(idx, "polarities",
                    Enums.Precision.INT32, toIntArr(acc.plaintextPolarities));
                writePrimitiveArray(idx, "precursor_mzs",
                    Enums.Precision.FLOAT64, toDoubleArr(acc.plaintextPmzs));
                writePrimitiveArray(idx, "precursor_charges",
                    Enums.Precision.INT32, toIntArr(acc.plaintextPcs));
                writePrimitiveArray(idx, "base_peak_intensities",
                    Enums.Precision.FLOAT64, toDoubleArr(acc.plaintextBpis));
            }
        }
        }  // run try-with-resources
        }  // sig try-with-resources
    }

    /** M90.8: materialise one genomic dataset into the destination .tio.
     *  Mirrors materialiseRun for genomic_runs/ subtree: writes the run
     *  group with modality/platform/reference_uri/sample_name attrs
     *  (parsed from instrument_json), the encrypted signal_channels
     *  segments, and the genomic_index columns + chromosomes compound. */
    private static void materialiseGenomicRun(StorageGroup gRuns,
                                                DatasetAccumulator acc,
                                                ProtectionMeta pm) {
        try (StorageGroup run = gRuns.createGroup(acc.name)) {
            run.setAttribute("acquisition_mode", (long) acc.acquisitionMode);
            run.setAttribute("spectrum_class", acc.spectrumClass);
            run.setAttribute("modality", extractJsonField(acc.instrumentJson, "modality"));
            run.setAttribute("platform", extractJsonField(acc.instrumentJson, "platform"));
            run.setAttribute("reference_uri", extractJsonField(acc.instrumentJson, "reference_uri"));
            run.setAttribute("sample_name", extractJsonField(acc.instrumentJson, "sample_name"));
            run.setAttribute("read_count", (long) acc.genomicChromosomes.size());

            try (StorageGroup sig = run.createGroup("signal_channels")) {
                StringBuilder cn = new StringBuilder();
                boolean first = true;
                for (String c : acc.channelNames) {
                    if (!first) cn.append(',');
                    cn.append(c);
                    first = false;
                }
                sig.setAttribute("channel_names", cn.toString());
                for (String cname : acc.channelNames) {
                    List<ChannelSegment> segs = acc.channelSegments.get(cname);
                    if (segs == null) continue;
                    PerAUFile.writeChannelSegments(sig, cname + "_segments", segs);
                    sig.setAttribute(cname + "_algorithm",
                        pm != null && pm.cipherSuite != null
                            ? pm.cipherSuite : "aes-256-gcm");
                    if (pm != null && pm.wrappedDek != null && pm.wrappedDek.length > 0) {
                        sig.setAttribute(cname + "_wrapped_dek", pm.wrappedDek);
                        sig.setAttribute(cname + "_kek_algorithm",
                                          pm.kekAlgorithm == null ? "" : pm.kekAlgorithm);
                    }
                }
            }

            try (StorageGroup idx = run.createGroup("genomic_index")) {
                int n = acc.genomicChromosomes.size();
                idx.setAttribute("count", (long) n);
                long[] offsetsArr = new long[n];
                int[] lengthsArr = new int[n];
                long[] positionsArr = new long[n];
                byte[] mqArr = new byte[n];
                int[] flagsArr = new int[n];
                List<ChannelSegment> firstSegs = acc.channelNames.isEmpty()
                    ? java.util.Collections.<ChannelSegment>emptyList()
                    : acc.channelSegments.get(acc.channelNames.get(0));
                for (int i = 0; i < n; i++) {
                    offsetsArr[i] = firstSegs != null && i < firstSegs.size() ? firstSegs.get(i).offset() : 0L;
                    lengthsArr[i] = firstSegs != null && i < firstSegs.size() ? firstSegs.get(i).length() : 0;
                    positionsArr[i] = acc.genomicPositions.get(i);
                    mqArr[i] = (byte) (acc.genomicMapqs.get(i) & 0xFF);
                    flagsArr[i] = (int) (acc.genomicFlags.get(i) & 0xFFFFFFFFL);
                }
                writePrimitiveArray(idx, "offsets", Enums.Precision.UINT64, offsetsArr);
                writePrimitiveArray(idx, "lengths", Enums.Precision.UINT32, lengthsArr);
                writePrimitiveArray(idx, "positions", Enums.Precision.INT64, positionsArr);
                writePrimitiveArray(idx, "mapping_qualities", Enums.Precision.UINT8, mqArr);
                writePrimitiveArray(idx, "flags", Enums.Precision.UINT32, flagsArr);
                writeChromosomesCompound(idx, acc.genomicChromosomes);
            }
        }
    }

    /** M90.8: minimal JSON value extractor for the metadata JSON we
     *  emit on the wire. Looks for the literal pattern "key": "value"
     *  and returns the captured value; returns the empty string when
     *  the key is not present or the JSON cannot be parsed. */
    private static String extractJsonField(String json, String key) {
        if (json == null || json.isEmpty()) return "";
        char QT = (char) 34;
        char BS = (char) 92;
        String needle = QT + key + QT + ": " + QT;
        int start = json.indexOf(needle);
        if (start < 0) return "";
        start += needle.length();
        // Walk forward looking for an unescaped closing quote.
        StringBuilder out = new StringBuilder();
        int i = start;
        while (i < json.length()) {
            char c = json.charAt(i);
            if (c == BS && i + 1 < json.length()) {
                out.append(json.charAt(i + 1));
                i += 2;
                continue;
            }
            if (c == QT) break;
            out.append(c);
            i++;
        }
        return out.toString();
    }

    /** M90.8: write a chromosomes compound dataset (single VL_STRING
     *  field {@code value}) mirroring the GenomicIndex layout.
     *  L1 (Task #82 Phase B.1, 2026-05-01): write chromosomes as
     *  {@code chromosome_ids} (uint16) + {@code chromosome_names}
     *  (compound) instead of a single VL-string compound. */
    private static void writeChromosomesCompound(StorageGroup idx,
                                                    List<String> chromosomes) {
        java.util.LinkedHashMap<String, Integer> nameToId = new java.util.LinkedHashMap<>();
        short[] ids = new short[chromosomes.size()];
        for (int i = 0; i < chromosomes.size(); i++) {
            String name = chromosomes.get(i);
            if (name == null) name = "";
            Integer slot = nameToId.get(name);
            if (slot == null) {
                if (nameToId.size() > 65535) {
                    throw new IllegalStateException(
                        "encrypted-transport: > 65,535 unique chromosome names");
                }
                slot = nameToId.size();
                nameToId.put(name, slot);
            }
            ids[i] = slot.shortValue();
        }
        try (StorageDataset cids = idx.createDataset(
                "chromosome_ids", Enums.Precision.UINT16, ids.length,
                0, Enums.Compression.NONE, 0)) {
            cids.writeAll(ids);
        }
        java.util.List<global.thalion.ttio.providers.CompoundField> fields =
            java.util.List.of(new global.thalion.ttio.providers.CompoundField(
                "name",
                global.thalion.ttio.providers.CompoundField.Kind.VL_STRING));
        java.util.List<Object[]> rows = new java.util.ArrayList<>(nameToId.size());
        for (String n : nameToId.keySet()) rows.add(new Object[]{ n });
        try (StorageDataset ds = idx.createCompoundDataset(
                "chromosome_names", fields, rows.size())) {
            ds.writeAll(rows);
        }
    }

    private static void writePrimitiveArray(StorageGroup parent, String name,
                                              Enums.Precision p, Object data) {
        int len = java.lang.reflect.Array.getLength(data);
        try (StorageDataset ds = parent.createDataset(name, p, len,
                0, Enums.Compression.NONE, 0)) {
            ds.writeAll(data);
        }
    }

    // ──────────────────────────────────────────────────────── helpers

    private static byte[] concat(byte[]... parts) {
        int n = 0;
        for (byte[] p : parts) n += p.length;
        byte[] out = new byte[n];
        int off = 0;
        for (byte[] p : parts) {
            System.arraycopy(p, 0, out, off, p.length);
            off += p.length;
        }
        return out;
    }

    private static String readLEString(ByteBuffer bb, int widthBytes) {
        int len = widthBytes == 2 ? (bb.getShort() & 0xFFFF) : bb.getInt();
        byte[] data = new byte[len];
        bb.get(data);
        return new String(data, StandardCharsets.UTF_8);
    }

    private static String attrStr(StorageGroup g, String name, String fallback) {
        if (!g.hasAttribute(name)) return fallback;
        Object v = g.getAttribute(name);
        return v == null ? fallback : v.toString();
    }

    private static byte[] attrBytes(StorageGroup g, String name) {
        if (!g.hasAttribute(name)) return new byte[0];
        Object v = g.getAttribute(name);
        if (v instanceof byte[] b) return b;
        if (v instanceof String s) return s.getBytes(StandardCharsets.UTF_8);
        return new byte[0];
    }

    private static int intAttr(StorageGroup g, String name, int fallback) {
        if (!g.hasAttribute(name)) return fallback;
        Object v = g.getAttribute(name);
        if (v instanceof Number n) return n.intValue();
        return fallback;
    }

    private static long firstChannelSegmentCount(StorageGroup sig, String firstCh) {
        List<ChannelSegment> segs = PerAUFile.readChannelSegments(
            sig, firstCh + "_segments");
        return segs.size();
    }

    private static List<String> splitNames(String raw) {
        if (raw == null || raw.isEmpty()) return List.of();
        String[] parts = raw.split(",");
        List<String> out = new ArrayList<>(parts.length);
        for (String p : parts) {
            String t = p.strip();
            if (!t.isEmpty()) out.add(t);
        }
        return out;
    }

    private static int wireFromSpectrumClass(String s) {
        return switch (s) {
            case "TTIONMRSpectrum" -> 1;
            case "TTIONMR2DSpectrum" -> 2;
            case "TTIOFreeInductionDecay" -> 3;
            case "TTIOMSImagePixel" -> 4;
            default -> 0;
        };
    }

    private static int polToWire(int polInt) {
        if (polInt == 1) return 0;
        if (polInt == -1) return 1;
        return 2;
    }

    private static double[] toDoubleArr(List<Double> xs) {
        double[] out = new double[xs.size()];
        for (int i = 0; i < xs.size(); i++) out[i] = xs.get(i);
        return out;
    }

    private static int[] toIntArr(List<Integer> xs) {
        int[] out = new int[xs.size()];
        for (int i = 0; i < xs.size(); i++) out[i] = xs.get(i);
        return out;
    }

    // ─────────────────────────────────────────── accumulator types

    static final class DatasetAccumulator {
        String name;
        int acquisitionMode;
        String spectrumClass;
        List<String> channelNames;
        Map<String, List<ChannelSegment>> channelSegments = new LinkedHashMap<>();
        List<HeaderSegment> headerSegments = new ArrayList<>();
        boolean usedEncryptedHeaders;
        List<Double> plaintextRts = new ArrayList<>();
        List<Integer> plaintextMsLevels = new ArrayList<>();
        List<Integer> plaintextPolarities = new ArrayList<>();
        List<Double> plaintextPmzs = new ArrayList<>();
        List<Integer> plaintextPcs = new ArrayList<>();
        List<Double> plaintextBpis = new ArrayList<>();
        // M90.8: genomic accumulator fields
        boolean isGenomic;
        String instrumentJson = "";
        List<String> genomicChromosomes = new ArrayList<>();
        List<Long> genomicPositions = new ArrayList<>();
        List<Integer> genomicMapqs = new ArrayList<>();
        List<Long> genomicFlags = new ArrayList<>();

        DatasetAccumulator(String name, int acqMode, String spectrumClass,
                             List<String> channelNames) {
            this(name, acqMode, spectrumClass, channelNames, "", false);
        }

        DatasetAccumulator(String name, int acqMode, String spectrumClass,
                             List<String> channelNames, String instrumentJson,
                             boolean isGenomic) {
            this.name = name;
            this.acquisitionMode = acqMode;
            this.spectrumClass = spectrumClass;
            this.channelNames = new ArrayList<>(channelNames);
            this.instrumentJson = instrumentJson == null ? "" : instrumentJson;
            this.isGenomic = isGenomic;
            for (String c : channelNames) {
                channelSegments.put(c, new ArrayList<>());
            }
        }
    }

    record ProtectionMeta(String cipherSuite, String kekAlgorithm,
                            byte[] wrappedDek) {}
}

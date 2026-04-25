/* TTI-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.ttio.protection;

import com.dtwthalion.ttio.Enums;
import com.dtwthalion.ttio.FeatureFlags;
import com.dtwthalion.ttio.protection.PerAUEncryption.ChannelSegment;
import com.dtwthalion.ttio.protection.PerAUEncryption.HeaderSegment;
import com.dtwthalion.ttio.providers.CompoundField;
import com.dtwthalion.ttio.providers.ProviderRegistry;
import com.dtwthalion.ttio.providers.StorageDataset;
import com.dtwthalion.ttio.providers.StorageGroup;
import com.dtwthalion.ttio.providers.StorageProvider;
import com.dtwthalion.ttio.transport.PacketHeader;
import com.dtwthalion.ttio.transport.PacketType;
import com.dtwthalion.ttio.transport.TransportReader;
import com.dtwthalion.ttio.transport.TransportWriter;

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
 * @since 1.0
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

    /** Emit the full transport stream from a per-AU-encrypted file. */
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

            try (StorageGroup study = root.openGroup("study");
                 StorageGroup msRuns = study.openGroup("ms_runs")) {
                String title = attrStr(study, "title", "");
                String isa = attrStr(study, "isa_investigation_id", "");

                List<String> runNames = new ArrayList<>();
                for (String n : msRuns.childNames()) {
                    if (!n.startsWith("_") && msRuns.hasChild(n)) runNames.add(n);
                }

                List<String> features = new ArrayList<>(flags.features());
                writer.writeStreamHeader("1.2", title, isa, features,
                                          runNames.size());

                // ── ProtectionMetadata + DatasetHeader per run ──
                int did = 1;
                for (String runName : runNames) {
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

                // ── AUs ───────────────────────────────────────
                did = 1;
                for (String runName : runNames) {
                    long n = emitRunAUs(writer, msRuns, runName, did,
                                          headersEncrypted);
                    writer.writeEndOfDataset(did, n);
                    did++;
                }
            }
            writer.writeEndOfStream();
        } finally {
            sp.close();
        }
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
                    datasets.put(h.datasetId,
                                  new DatasetAccumulator(h.name, h.acqMode,
                                                            h.spectrumClass,
                                                            h.channelNames));
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
        // instrument_json + expected_au_count follow; not needed for
        // file materialisation (reader recomputes from AUs).
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
            bb.get(); // spectrum_class (already set by DatasetHeader)
            int nChannels = bb.get() & 0xFF;
            byte[] iv = new byte[12]; bb.get(iv);
            byte[] tag = new byte[16]; bb.get(tag);
            byte[] ct = new byte[36]; bb.get(ct);
            acc.headerSegments.add(new HeaderSegment(iv, tag, ct));
            readEncryptedChannels(bb, nChannels, acc);
        } else {
            bb.get();                 // spectrum_class
            int acq = bb.get() & 0xFF;
            int msLevel = bb.get() & 0xFF;
            int polWire = bb.get() & 0xFF;
            double rt = bb.getDouble();
            double pmz = bb.getDouble();
            int pc = bb.get() & 0xFF;
            double ionMob = bb.getDouble();
            double bpi = bb.getDouble();
            int nChannels = bb.get() & 0xFF;
            acc.plaintextRts.add(rt);
            acc.plaintextMsLevels.add(msLevel);
            acc.plaintextPolarities.add(polWire == 0 ? 1 : polWire == 1 ? -1 : 0);
            acc.plaintextPmzs.add(pmz);
            acc.plaintextPcs.add(pc);
            acc.plaintextBpis.add(bpi);
            if (acc.acquisitionMode == 0) acc.acquisitionMode = acq;
            readEncryptedChannels(bb, nChannels, acc);
            @SuppressWarnings("unused") double _im = ionMob;
        }
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
            new FeatureFlags("1.1", features).writeTo(root);

            try (StorageGroup study = root.createGroup("study")) {
                study.setAttribute("title", title == null ? "" : title);
                study.setAttribute("isa_investigation_id",
                                     isa == null ? "" : isa);

                try (StorageGroup msRuns = study.createGroup("ms_runs")) {
                    StringBuilder runNamesJoined = new StringBuilder();
                    boolean first = true;
                    for (DatasetAccumulator acc : datasets.values()) {
                        if (!first) runNamesJoined.append(',');
                        runNamesJoined.append(acc.name);
                        first = false;
                    }
                    msRuns.setAttribute("_run_names", runNamesJoined.toString());

                    for (Map.Entry<Integer, DatasetAccumulator> e : datasets.entrySet()) {
                        materialiseRun(msRuns, e.getValue(),
                                         protection.get(e.getKey()));
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

        DatasetAccumulator(String name, int acqMode, String spectrumClass,
                             List<String> channelNames) {
            this.name = name;
            this.acquisitionMode = acqMode;
            this.spectrumClass = spectrumClass;
            this.channelNames = new ArrayList<>(channelNames);
            for (String c : channelNames) {
                channelSegments.put(c, new ArrayList<>());
            }
        }
    }

    record ProtectionMeta(String cipherSuite, String kekAlgorithm,
                            byte[] wrappedDek) {}
}

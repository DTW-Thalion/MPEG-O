/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;

/**
 * Lazy view over one {@code /study/genomic_runs/<name>/} group.
 *
 * <p>Materialises {@link AlignedRead} objects on demand from the
 * signal channels. The {@link GenomicIndex} is loaded eagerly at
 * open time for cheap filtering and offset lookups; the heavy signal
 * channels (sequences, qualities, plus 3 compounds) stay lazy.</p>
 *
 * <p>Genomic analogue of
 * {@link global.thalion.ttio.AcquisitionRun}.</p>
 *
 * <p><b>API status:</b> Stable (v0.11 M82.3).</p>
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOGenomicRun}, Python {@code ttio.genomic_run.GenomicRun}.</p>
 */
public class GenomicRun
        implements global.thalion.ttio.protocols.Indexable<AlignedRead>,
                   global.thalion.ttio.protocols.Streamable<AlignedRead>,
                   AutoCloseable {

    private final String name;
    private final AcquisitionMode acquisitionMode;
    private final String modality;
    private final String referenceUri;
    private final String platform;
    private final String sampleName;
    private final GenomicIndex index;
    private final StorageGroup runGroup;

    private StorageGroup signalChannels;                       // lazy
    private StorageDataset sequencesDs;                        // lazy
    private StorageDataset qualitiesDs;                        // lazy
    private final Map<String, List<Object[]>> compoundCache = new HashMap<>();
    // M86: lazy whole-channel decode cache for byte channels whose
    // @compression attribute names a TTI-O codec (rANS / BASE_PACK).
    // Codec output is byte-stream non-sliceable, so the whole channel
    // is decoded once on first access and the decoded buffer is sliced
    // from memory thereafter (Binding Decision §89). Cache lifetime is
    // this GenomicRun instance — re-opening the file incurs the decode
    // cost again (Gotcha §101). Mutable HashMap, not Map.of(), so the
    // dispatch helper can populate it.
    private final Map<String, byte[]> decodedByteChannels = new HashMap<>();

    private int cursor = 0;  // Streamable

    private GenomicRun(String name, AcquisitionMode acquisitionMode,
                       String modality, String referenceUri,
                       String platform, String sampleName,
                       GenomicIndex index, StorageGroup runGroup) {
        this.name = name;
        this.acquisitionMode = acquisitionMode;
        this.modality = modality;
        this.referenceUri = referenceUri;
        this.platform = platform;
        this.sampleName = sampleName;
        this.index = index;
        this.runGroup = runGroup;
    }

    public String name()                       { return name; }
    public AcquisitionMode acquisitionMode()   { return acquisitionMode; }
    public String modality()                   { return modality; }
    public String referenceUri()               { return referenceUri; }
    public String platform()                   { return platform; }
    public String sampleName()                 { return sampleName; }
    public GenomicIndex index()                { return index; }
    public int readCount()                     { return index.count(); }

    /** Open an existing genomic_runs/&lt;name&gt;/ group. The caller
     *  resolves the run group and passes it as {@code runGroup}. */
    public static GenomicRun readFrom(StorageGroup runGroup, String name) {
        GenomicIndex idx;
        try (StorageGroup ig = runGroup.openGroup("genomic_index")) {
            idx = GenomicIndex.readFrom(ig);
        }
        Object modeObj = runGroup.getAttribute("acquisition_mode");
        AcquisitionMode mode = AcquisitionMode.values()[
            modeObj == null ? 0 : ((Number) modeObj).intValue()];
        String modality   = stringAttr(runGroup, "modality",       "genomic_sequencing");
        String refUri     = stringAttr(runGroup, "reference_uri",  "");
        String platform   = stringAttr(runGroup, "platform",       "");
        String sampleName = stringAttr(runGroup, "sample_name",    "");
        return new GenomicRun(name, mode, modality, refUri, platform,
                              sampleName, idx, runGroup);
    }

    /** Materialise read at index {@code i}. {@link Indexable} requires
     *  this signature. The shorthand {@code readAt} is provided as a
     *  domain-natural alias. */
    @Override
    public AlignedRead objectAtIndex(int i) {
        if (i < 0 || i >= index.count()) {
            throw new IndexOutOfBoundsException(
                "read index " + i + " out of range [0, " + index.count() + ")");
        }
        long offset = index.offsetAt(i);
        int  length = index.lengthAt(i);

        ensureSignalChannels();
        // M86: routed through byteChannelSlice so that channels written
        // with a TTIO codec override (@compression > 0) are decoded
        // transparently before slicing.
        byte[] seqBytes = byteChannelSlice("sequences", offset, length);
        String sequence = new String(seqBytes, StandardCharsets.US_ASCII);
        byte[] qualities = byteChannelSlice("qualities", offset, length);

        // Compound rows (cached on first access)
        List<Object[]> cigars     = compoundRows("cigars");
        List<Object[]> readNames  = compoundRows("read_names");
        List<Object[]> mateInfos  = compoundRows("mate_info");

        String cigar    = stringFromCompound(cigars.get(i)[0]);
        String readName = stringFromCompound(readNames.get(i)[0]);
        Object[] mate   = mateInfos.get(i);
        String mateChrom = stringFromCompound(mate[0]);
        long matePos     = ((Number) mate[1]).longValue();
        int  tlen        = ((Number) mate[2]).intValue();

        return new AlignedRead(
            readName,
            index.chromosomeAt(i),
            index.positionAt(i),
            index.mappingQualityAt(i),
            cigar,
            sequence,
            qualities,
            index.flagsAt(i),
            mateChrom,
            matePos,
            tlen);
    }

    /** Domain-natural alias for {@link #objectAtIndex(int)}. */
    public AlignedRead readAt(int i) { return objectAtIndex(i); }

    /** Reads on {@code chromosome} whose mapping position is in
     *  {@code [start, end)}. */
    public List<AlignedRead> readsInRegion(String chromosome,
                                            long start, long end) {
        List<Integer> indices = index.indicesForRegion(chromosome, start, end);
        List<AlignedRead> out = new ArrayList<>(indices.size());
        for (int i : indices) out.add(objectAtIndex(i));
        return out;
    }

    // ── Indexable<AlignedRead> ─────────────────────────────────────

    @Override public int count() { return readCount(); }

    // ── Streamable<AlignedRead> ────────────────────────────────────

    @Override public boolean hasMore() { return cursor < readCount(); }
    @Override public AlignedRead nextObject() {
        if (!hasMore()) throw new NoSuchElementException();
        return objectAtIndex(cursor++);
    }
    @Override public int currentPosition() { return cursor; }
    @Override public boolean seekToPosition(int position) {
        if (position < 0 || position > readCount()) return false;
        cursor = position;
        return true;
    }
    @Override public void reset() { cursor = 0; }

    @Override
    public void close() {
        if (sequencesDs != null) { sequencesDs.close(); sequencesDs = null; }
        if (qualitiesDs != null) { qualitiesDs.close(); qualitiesDs = null; }
        if (signalChannels != null) { signalChannels.close(); signalChannels = null; }
    }

    // ── Internal helpers ───────────────────────────────────────────

    private void ensureSignalChannels() {
        if (signalChannels == null) {
            signalChannels = runGroup.openGroup("signal_channels");
            sequencesDs = signalChannels.openDataset("sequences");
            qualitiesDs = signalChannels.openDataset("qualities");
        }
    }

    /** M86: slice {@code count} bytes starting at {@code offset} from a
     *  uint8 byte channel. For codec-compressed channels
     *  ({@code @compression > 0}) the whole channel is decoded once on
     *  first access, the decoded buffer is cached on this
     *  {@link GenomicRun} instance, and subsequent slices come from the
     *  cached array. For uncompressed channels (no attribute or value
     *  0) the existing per-slice {@link StorageDataset#readSlice} path
     *  is used unchanged. */
    private byte[] byteChannelSlice(String name, long offset, int count) {
        byte[] cached = decodedByteChannels.get(name);
        if (cached != null) {
            byte[] out = new byte[count];
            System.arraycopy(cached, (int) offset, out, 0, count);
            return out;
        }
        StorageDataset ds = "sequences".equals(name) ? sequencesDs
                          : "qualities".equals(name) ? qualitiesDs
                          : signalChannels.openDataset(name);
        Object codecAttr = ds.getAttribute("compression");
        long codecId = (codecAttr instanceof Number n) ? n.longValue() : 0L;
        if (codecId == 0L) {
            return (byte[]) ds.readSlice(offset, count);
        }
        // Compressed: read the whole channel, decode once, cache.
        long total = ds.shape()[0];
        byte[] all = (byte[]) ds.readSlice(0L, total);
        byte[] decoded;
        if (codecId == global.thalion.ttio.Enums.Compression.RANS_ORDER0.ordinal()) {
            decoded = global.thalion.ttio.codecs.Rans.decode(all);
        } else if (codecId == global.thalion.ttio.Enums.Compression.RANS_ORDER1.ordinal()) {
            decoded = global.thalion.ttio.codecs.Rans.decode(all);
        } else if (codecId == global.thalion.ttio.Enums.Compression.BASE_PACK.ordinal()) {
            decoded = global.thalion.ttio.codecs.BasePack.decode(all);
        } else {
            throw new IllegalStateException(
                "signal_channel '" + name + "': @compression="
                + codecId + " is not a supported TTIO codec id");
        }
        decodedByteChannels.put(name, decoded);
        byte[] out = new byte[count];
        System.arraycopy(decoded, (int) offset, out, 0, count);
        return out;
    }

    @SuppressWarnings("unchecked")
    private List<Object[]> compoundRows(String name) {
        List<Object[]> rows = compoundCache.get(name);
        if (rows == null) {
            ensureSignalChannels();
            try (StorageDataset ds = signalChannels.openDataset(name)) {
                rows = (List<Object[]>) ds.readAll();
            }
            compoundCache.put(name, rows);
        }
        return rows;
    }

    private static String stringFromCompound(Object v) {
        if (v == null) return "";
        if (v instanceof byte[] b) return new String(b, StandardCharsets.UTF_8);
        return (String) v;
    }

    private static String stringAttr(StorageGroup g, String name, String fallback) {
        try {
            Object v = g.getAttribute(name);
            if (v instanceof String s) return s;
            if (v instanceof byte[] b) return new String(b, StandardCharsets.UTF_8);
            return v == null ? fallback : v.toString();
        } catch (Exception e) {
            return fallback;
        }
    }
}

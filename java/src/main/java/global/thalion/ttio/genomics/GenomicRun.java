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
    // M86 Phase E: lazy decode cache for the read_names channel when it
    // carries a NAME_TOKENIZED codec override. Held as a List<String>
    // (not byte[]) per Binding Decision §114 — different value type and
    // semantics from decodedByteChannels (which holds raw byte buffers
    // sliced by per-read offset/length). The whole list is materialised
    // on first access regardless of the access pattern.
    private List<String> decodedReadNames = null;
    // M86 Phase C: lazy decode cache for the cigars channel when it
    // carries an RANS_ORDER0 / RANS_ORDER1 / NAME_TOKENIZED codec
    // override. Held as a List<String> mirroring decodedReadNames per
    // Binding Decision §123 — separate cache from decodedReadNames
    // (Option A from §2.3, lower-risk than a generalised dict).
    private List<String> decodedCigars = null;
    // M86 Phase B: lazy decode cache for integer channels. Per Binding
    // Decision §116 this is a separate cache from decodedByteChannels
    // (byte[]) and decodedReadNames (List<String>) because the value
    // type differs — typed integer arrays (long[]/int[]/byte[]). The
    // decode happens whole-channel on first access through
    // intChannelArray(name); per Binding Decision §119 alignedReadAt
    // does NOT consume this cache (it still uses self.index for per-
    // read integer fields), so this cache is exercised by callers that
    // want bulk access to the compressed signal_channels integer data.
    private final Map<String, Object> decodedIntChannels = new HashMap<>();

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

        // Compound rows (cached on first access). M86 Phase E:
        // read_names is dispatched separately via readNameAt() since
        // the dataset shape varies (compound vs flat uint8 codec).
        // M86 Phase C: cigars likewise dispatched via cigarAt() since
        // the dataset shape varies (compound vs flat uint8 codec).
        List<Object[]> mateInfos  = compoundRows("mate_info");

        String cigar    = cigarAt(i);
        String readName = readNameAt(i);
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
        } else if (codecId == global.thalion.ttio.Enums.Compression.QUALITY_BINNED.ordinal()) {
            // M86 Phase D: lossy Phred bin quantisation (M85 §97).
            // Caller of byteChannelSlice gets the bin-centre values,
            // not the original Phred bytes.
            decoded = global.thalion.ttio.codecs.Quality.decode(all);
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

    /** M86 Phase E: return the read name at index {@code i}, dispatching
     *  on dataset shape (Binding Decisions §111, §112).
     *
     *  <p>Two on-disk layouts:
     *  <ul>
     *    <li><b>M82 compound</b> (no override): VL_STRING-in-compound
     *        dataset, read whole-and-cache via {@link #compoundRows}.</li>
     *    <li><b>NAME_TOKENIZED</b> (override active): flat 1-D uint8
     *        dataset. The whole channel is read, decoded once via
     *        {@link global.thalion.ttio.codecs.NameTokenizer#decode},
     *        and cached as a {@code List<String>} on this instance per
     *        Binding Decision §114 (separate from
     *        {@link #decodedByteChannels}).</li>
     *  </ul>
     *
     *  <p>Dispatch is on the dataset's
     *  {@link StorageDataset#precision()} — {@code Precision.UINT8}
     *  routes through the codec path; {@code null} (the marker for a
     *  compound dataset on the Hdf5Provider adapter) falls through to
     *  the M82 compound path. */
    private String readNameAt(int i) {
        List<String> cached = decodedReadNames;
        if (cached != null) {
            return cached.get(i);
        }
        ensureSignalChannels();
        try (StorageDataset ds = signalChannels.openDataset("read_names")) {
            global.thalion.ttio.Enums.Precision p = ds.precision();
            if (p == global.thalion.ttio.Enums.Precision.UINT8) {
                Object codecAttr = ds.getAttribute("compression");
                long codecId = (codecAttr instanceof Number n)
                    ? n.longValue() : 0L;
                if (codecId == global.thalion.ttio.Enums.Compression
                        .NAME_TOKENIZED.ordinal()) {
                    long total = ds.shape()[0];
                    byte[] all = (byte[]) ds.readSlice(0L, total);
                    decodedReadNames = global.thalion.ttio.codecs
                        .NameTokenizer.decode(all);
                    return decodedReadNames.get(i);
                }
                throw new IllegalStateException(
                    "signal_channel 'read_names': @compression="
                    + codecId + " is not a supported TTIO codec id "
                    + "for the read_names channel (only NAME_TOKENIZED "
                    + "= 8 is recognised)");
            }
        }
        // Compound path (M82, no override).
        List<Object[]> rows = compoundRows("read_names");
        return stringFromCompound(rows.get(i)[0]);
    }

    /** M86 Phase C: return the cigar string at index {@code i},
     *  dispatching on dataset shape (Binding Decisions §120-§123).
     *
     *  <p>Two on-disk layouts:
     *  <ul>
     *    <li><b>M82 compound</b> (no override): VL_STRING-in-compound
     *        dataset, read whole-and-cache via {@link #compoundRows}.</li>
     *    <li><b>TTIO codec</b> (override active): flat 1-D uint8
     *        dataset. The whole channel is read, decoded once, and
     *        cached as a {@code List<String>} on this instance per
     *        Binding Decision §123 (separate from
     *        {@link #decodedReadNames} per Option A from the Phase C
     *        plan §2.3).
     *      <ul>
     *        <li>RANS_ORDER0 / RANS_ORDER1: decoded byte buffer is a
     *            length-prefix-concat sequence ({@code varint(len) +
     *            bytes} per CIGAR). Walk the buffer to reconstruct
     *            the {@code List<String>}.</li>
     *        <li>NAME_TOKENIZED: pass the bytes through
     *            {@link global.thalion.ttio.codecs.NameTokenizer#decode}
     *            directly.</li>
     *      </ul>
     *    </li>
     *  </ul>
     *
     *  <p>Per Gotcha §139 the rANS path uses raw length-prefix-concat
     *  (NOT NAME_TOKENIZED's verbatim format then rANS-encoded). */
    private String cigarAt(int i) {
        List<String> cached = decodedCigars;
        if (cached != null) {
            return cached.get(i);
        }
        ensureSignalChannels();
        try (StorageDataset ds = signalChannels.openDataset("cigars")) {
            global.thalion.ttio.Enums.Precision p = ds.precision();
            if (p == global.thalion.ttio.Enums.Precision.UINT8) {
                Object codecAttr = ds.getAttribute("compression");
                long codecId = (codecAttr instanceof Number n)
                    ? n.longValue() : 0L;
                long total = ds.shape()[0];
                byte[] all = (byte[]) ds.readSlice(0L, total);
                if (codecId == global.thalion.ttio.Enums.Compression
                        .RANS_ORDER0.ordinal()
                    || codecId == global.thalion.ttio.Enums.Compression
                        .RANS_ORDER1.ordinal()) {
                    byte[] decoded = global.thalion.ttio.codecs
                        .Rans.decode(all);
                    decodedCigars = decodeLengthPrefixConcat(decoded);
                    return decodedCigars.get(i);
                }
                if (codecId == global.thalion.ttio.Enums.Compression
                        .NAME_TOKENIZED.ordinal()) {
                    decodedCigars = global.thalion.ttio.codecs
                        .NameTokenizer.decode(all);
                    return decodedCigars.get(i);
                }
                throw new IllegalStateException(
                    "signal_channel 'cigars': @compression="
                    + codecId + " is not a supported TTIO codec id "
                    + "for the cigars channel (only RANS_ORDER0 = 4, "
                    + "RANS_ORDER1 = 5, and NAME_TOKENIZED = 8 are "
                    + "recognised)");
            }
        }
        // Compound path (M82, no override).
        List<Object[]> rows = compoundRows("cigars");
        return stringFromCompound(rows.get(i)[0]);
    }

    /** Walk a length-prefix-concat byte buffer back into a list of
     *  ASCII strings. Each entry is {@code varint(len) + len bytes} of
     *  ASCII payload; iteration stops when the buffer is exhausted. */
    private static List<String> decodeLengthPrefixConcat(byte[] buf) {
        List<String> out = new ArrayList<>();
        int offset = 0;
        int n = buf.length;
        long[] tmp = new long[1];
        while (offset < n) {
            offset = readUnsignedVarint(buf, offset, tmp);
            long lengthL = tmp[0];
            if (lengthL < 0 || lengthL > Integer.MAX_VALUE) {
                throw new IllegalArgumentException(
                    "cigars rANS stream: length-prefix-concat entry "
                    + "length " + lengthL + " out of int range");
            }
            int length = (int) lengthL;
            if (offset + length > n) {
                throw new IllegalArgumentException(
                    "cigars rANS stream: length-prefix-concat entry "
                    + "runs off end of decoded buffer (offset="
                    + offset + ", length=" + length
                    + ", buffer_size=" + n + ")");
            }
            for (int k = 0; k < length; k++) {
                int b = Byte.toUnsignedInt(buf[offset + k]);
                if (b > 0x7F) {
                    throw new IllegalArgumentException(
                        "cigars rANS stream: entry contains "
                        + "non-ASCII bytes");
                }
            }
            out.add(new String(buf, offset, length,
                StandardCharsets.US_ASCII));
            offset += length;
        }
        return out;
    }

    /** Unsigned LEB128 varint reader matching the writer in
     *  {@link global.thalion.ttio.SpectralDataset}. Returns the new
     *  offset; the decoded value is stored in {@code out[0]}. */
    private static int readUnsignedVarint(byte[] buf, int offset, long[] out) {
        long value = 0;
        int shift = 0;
        int pos = offset;
        int n = buf.length;
        while (true) {
            if (pos >= n) {
                throw new IllegalArgumentException(
                    "cigars rANS stream: varint runs off end of buffer "
                    + "at offset " + offset);
            }
            int b = Byte.toUnsignedInt(buf[pos]);
            pos++;
            value |= ((long) (b & 0x7F)) << shift;
            if ((b & 0x80) == 0) {
                out[0] = value;
                return pos;
            }
            shift += 7;
            if (shift > 63) {
                throw new IllegalArgumentException(
                    "cigars rANS stream: varint overflow at offset "
                    + offset);
            }
        }
    }

    /** M86 Phase B: return the full integer array for the named
     *  signal channel, lazily decoded on first access.
     *
     *  <p>Channel-name → return type mapping (Binding Decision §115):
     *  <ul>
     *    <li>{@code positions} → {@code long[]} (int64 LE)</li>
     *    <li>{@code flags} → {@code int[]} (uint32 LE)</li>
     *    <li>{@code mapping_qualities} → {@code byte[]} (uint8)</li>
     *  </ul>
     *
     *  <p>For codec-compressed channels ({@code @compression > 0}) the
     *  whole dataset is read once on first access, decoded through
     *  {@link global.thalion.ttio.codecs.Rans#decode}, re-interpreted
     *  via {@link java.nio.ByteOrder#LITTLE_ENDIAN}, and cached on this
     *  {@link GenomicRun} per Binding Decision §116. For uncompressed
     *  channels the dataset is read directly with its natural dtype.
     *
     *  <p>Per Binding Decision §119 this helper is callable but is NOT
     *  consumed by {@link #objectAtIndex(int)} — the legacy read path
     *  for per-read integer fields uses {@link #index} (the duplicated
     *  {@code genomic_index/} arrays). Phase B compression on
     *  {@code signal_channels/} integer datasets is therefore a
     *  write-side file-size optimisation; tests verify the round-trip
     *  by calling this helper directly. */
    public Object intChannelArray(String name) {
        Object cached = decodedIntChannels.get(name);
        if (cached != null) return cached;

        global.thalion.ttio.Enums.Precision naturalDtype;
        switch (name) {
            case "positions" -> naturalDtype = global.thalion.ttio.Enums
                .Precision.INT64;
            case "flags" -> naturalDtype = global.thalion.ttio.Enums
                .Precision.UINT32;
            case "mapping_qualities" -> naturalDtype = global.thalion.ttio
                .Enums.Precision.UINT8;
            default -> throw new IllegalArgumentException(
                "intChannelArray: unknown integer channel '" + name + "'");
        }

        ensureSignalChannels();
        try (StorageDataset ds = signalChannels.openDataset(name)) {
            Object codecAttr = ds.getAttribute("compression");
            long codecId = (codecAttr instanceof Number n)
                ? n.longValue() : 0L;
            if (codecId == 0L) {
                // Uncompressed: dataset stored at its natural integer
                // precision; readAll returns the typed array directly.
                Object arr = ds.readAll();
                decodedIntChannels.put(name, arr);
                return arr;
            }
            if (codecId == global.thalion.ttio.Enums.Compression
                    .RANS_ORDER0.ordinal()
                || codecId == global.thalion.ttio.Enums.Compression
                    .RANS_ORDER1.ordinal()) {
                long total = ds.shape()[0];
                byte[] all = (byte[]) ds.readSlice(0L, total);
                byte[] decoded = global.thalion.ttio.codecs.Rans.decode(all);
                Object arr = deserialiseLeBytes(decoded, naturalDtype);
                decodedIntChannels.put(name, arr);
                return arr;
            }
            throw new IllegalStateException(
                "signal_channel '" + name + "': @compression=" + codecId
                + " is not a supported TTIO codec id for an integer "
                + "channel (only RANS_ORDER0 = 4 and RANS_ORDER1 = 5 "
                + "are recognised)");
        }
    }

    /** M86 Phase B: re-interpret a little-endian byte buffer as the
     *  channel's natural integer array. */
    private static Object deserialiseLeBytes(
            byte[] bytes,
            global.thalion.ttio.Enums.Precision precision) {
        java.nio.ByteBuffer bb = java.nio.ByteBuffer.wrap(bytes)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN);
        switch (precision) {
            case INT64 -> {
                int n = bytes.length / 8;
                long[] out = new long[n];
                for (int i = 0; i < n; i++) out[i] = bb.getLong();
                return out;
            }
            case UINT32 -> {
                int n = bytes.length / 4;
                int[] out = new int[n];
                for (int i = 0; i < n; i++) out[i] = bb.getInt();
                return out;
            }
            case UINT8 -> {
                return bytes.clone();
            }
            default -> throw new IllegalArgumentException(
                "deserialiseLeBytes: unsupported precision " + precision);
        }
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

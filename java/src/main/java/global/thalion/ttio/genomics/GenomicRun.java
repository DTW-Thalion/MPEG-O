/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.ProvenanceRecord;
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
                   global.thalion.ttio.protocols.Run,
                   AutoCloseable {

    private final String name;
    private final AcquisitionMode acquisitionMode;
    private final String modality;
    private final String referenceUri;
    private final String platform;
    private final String sampleName;
    private final GenomicIndex index;
    private final StorageGroup runGroup;
    // Phase 1 (post-M91): per-run provenance, cached at open time so
    // provenanceChain() is a pure accessor. Eager because the on-disk
    // form is a small JSON attribute on the run group; lazy decode
    // would buy nothing and would complicate the Run protocol surface.
    private final List<ProvenanceRecord> provenanceRecords;

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
    // M86 Phase F: combined per-field cache for the mate_info subgroup
    // layout (Binding Decision §129). Keyed by on-disk child name
    // ("chrom" → List<String>; "pos" → long[]; "tlen" → int[]).
    // Separate from compoundCache (M82 path), decodedByteChannels,
    // decodedReadNames, decodedCigars, decodedIntChannels — three
    // value types in one cache, one entry per per-read decode.
    // Mutable HashMap so the per-field accessors can populate it.
    private final Map<String, Object> decodedMateInfo = new HashMap<>();

    private int cursor = 0;  // Streamable

    private GenomicRun(String name, AcquisitionMode acquisitionMode,
                       String modality, String referenceUri,
                       String platform, String sampleName,
                       GenomicIndex index, StorageGroup runGroup,
                       List<ProvenanceRecord> provenanceRecords) {
        this.name = name;
        this.acquisitionMode = acquisitionMode;
        this.modality = modality;
        this.referenceUri = referenceUri;
        this.platform = platform;
        this.sampleName = sampleName;
        this.index = index;
        this.runGroup = runGroup;
        this.provenanceRecords = provenanceRecords != null
            ? List.copyOf(provenanceRecords) : List.of();
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
        List<ProvenanceRecord> prov = readPerRunProvenance(runGroup);
        return new GenomicRun(name, mode, modality, refUri, platform,
                              sampleName, idx, runGroup, prov);
    }

    /** Phase 2 (post-M91): read per-run provenance. Prefers the
     *  canonical compound dataset {@code provenance/steps} (matches
     *  Python's writer and Java's HDF5 fast path), falling back to
     *  the {@code provenance_json} attribute for non-HDF5 providers
     *  (memory/sqlite/zarr) and legacy Java-written files. */
    private static List<ProvenanceRecord> readPerRunProvenance(StorageGroup runGroup) {
        if (runGroup.hasChild("provenance")) {
            try (StorageGroup prov = runGroup.openGroup("provenance")) {
                global.thalion.ttio.hdf5.Hdf5Group h5 =
                    global.thalion.ttio.providers.Hdf5Provider
                        .tryUnwrapHdf5Group(prov);
                if (h5 != null && h5.hasChild("steps")) {
                    List<Object[]> rows =
                        global.thalion.ttio.hdf5.Hdf5CompoundIO
                            .readCompoundFull(h5, "steps",
                                global.thalion.ttio.hdf5.Hdf5CompoundIO
                                    .provenanceSchema());
                    List<ProvenanceRecord> out = new ArrayList<>(rows.size());
                    for (Object[] r : rows) {
                        out.add(new ProvenanceRecord(
                            ((Number) r[0]).longValue(),
                            (String) r[1],
                            global.thalion.ttio.MiniJson.parseStringMap(
                                (String) r[2]),
                            global.thalion.ttio.MiniJson.parseArrayOfStrings(
                                (String) r[3]),
                            global.thalion.ttio.MiniJson.parseArrayOfStrings(
                                (String) r[4])));
                    }
                    return out;
                }
            }
        }
        if (!runGroup.hasAttribute("provenance_json")) {
            return List.of();
        }
        Object v = runGroup.getAttribute("provenance_json");
        if (v == null) return List.of();
        String json = v instanceof String s ? s
                    : v instanceof byte[] b ? new String(b, StandardCharsets.UTF_8)
                    : v.toString();
        return global.thalion.ttio.ProvenanceJsonParse.parseArray(json);
    }

    /** M90.10: probe the {@code @compression} attribute on a
     *  signal_channels child dataset. Returns the codec id (an
     *  {@link global.thalion.ttio.Enums.Compression} ordinal), or 0
     *  ({@code NONE}) when the attribute is absent or the channel
     *  doesn't exist. Used by
     *  {@link global.thalion.ttio.transport.TransportWriter} to mirror
     *  the file's per-channel codec choice on the wire. */
    public int signalChannelCompressionCode(String channelName) {
        ensureSignalChannels();
        if (!signalChannels.hasChild(channelName)) return 0;
        try (StorageDataset ds = signalChannels.openDataset(channelName)) {
            Object v = ds.getAttribute("compression");
            if (v instanceof Number n) return n.intValue();
            return 0;
        } catch (Exception e) {
            return 0;
        }
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

        // M86 Phase E: read_names dispatched separately via
        // readNameAt() (the dataset shape varies — compound vs flat
        // uint8 codec). M86 Phase C: cigars likewise via cigarAt().
        // M86 Phase F: mate fields dispatched via three per-field
        // accessors (mateChromAt / matePosAt / mateTlenAt) since the
        // mate_info link can be either an M82 compound dataset OR a
        // Phase F subgroup containing three child datasets (Binding
        // Decision §128, link-type dispatch).
        String cigar     = cigarAt(i);
        String readName  = readNameAt(i);
        String mateChrom = mateChromAt(i);
        long   matePos   = matePosAt(i);
        int    tlen      = mateTlenAt(i);

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

    // ── Run conformance (Phase 1, post-M91) ────────────────────────

    /** Phase 1: modality-agnostic accessor required by
     *  {@link global.thalion.ttio.protocols.Run}. Delegates to
     *  {@link #objectAtIndex(int)}; the typed return is widened to
     *  {@code Object} so callers iterating uniformly over
     *  AcquisitionRun + GenomicRun see a single signature. */
    @Override
    public Object get(int index) { return objectAtIndex(index); }

    /** Phase 1 (post-M91): per-run provenance chain in insertion
     *  order. Closes the M91 read-side gap — until Phase 1 the lazy
     *  {@code GenomicRun} view didn't expose provenance, so cross-
     *  modality queries had to fall back to the {@code @sample_name}
     *  attribute. Returns an empty list for runs that carry no
     *  provenance.
     *
     *  <p>Source of record: the {@code provenance_json} attribute on
     *  the {@code /study/genomic_runs/<name>/} group, written by
     *  {@link global.thalion.ttio.SpectralDataset#writeGenomicRunSubtree}
     *  (Phase 1) — same on-disk pattern as
     *  {@link global.thalion.ttio.AcquisitionRun#writeProvenance}.</p> */
    @Override
    public List<ProvenanceRecord> provenanceChain() {
        return provenanceRecords;
    }

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
        } else if (codecId == global.thalion.ttio.Enums.Compression.REF_DIFF.ordinal()) {
            // M93 v1.2: REF_DIFF is context-aware. Resolve the
            // reference via ReferenceResolver, then decode the per-
            // read slices and concatenate into the M82 contract: a
            // flat uint8 byte stream the same length as sum(lengths).
            decoded = decodeRefDiffSequences(all);
        } else if (codecId == global.thalion.ttio.Enums.Compression
                .FQZCOMP_NX16.ordinal()) {
            // M94 v1.2: FQZCOMP_NX16 is a v1.5 quality codec. The
            // wire format carries read_lengths in the header sidecar;
            // revcomp_flags must be reconstructed from the M86 flags
            // channel (run.flags()[i] & 16, the SAM REVERSE bit).
            int n = index.count();
            int[] revcompFlags = new int[n];
            for (int i = 0; i < n; i++) {
                int f = index.flagsAt(i);
                revcompFlags[i] = ((f & 16) != 0) ? 1 : 0;
            }
            global.thalion.ttio.codecs.FqzcompNx16.DecodeResult dr =
                global.thalion.ttio.codecs.FqzcompNx16
                    .decodeWithMetadata(all, revcompFlags);
            decoded = dr.qualities();
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

    /** M93 v1.2: decode the {@code sequences} channel encoded with the
     *  REF_DIFF codec. Returns the concatenated per-read sequence bytes
     *  — same shape and dtype contract as the M82 sequences channel
     *  (uint8 1-D byte stream of total length sum(lengths)).
     *
     *  @throws global.thalion.ttio.codecs.RefMissingException when the
     *      reference can't be resolved. */
    private byte[] decodeRefDiffSequences(byte[] encoded) {
        global.thalion.ttio.codecs.RefDiff.HeaderUnpack hu =
            global.thalion.ttio.codecs.RefDiff.unpackCodecHeader(encoded);
        // ReferenceResolver wants an Hdf5File; the writer always
        // embeds at /study/references/<uri>/ in the same file.
        global.thalion.ttio.hdf5.Hdf5Group h5g = global.thalion.ttio.providers
            .Hdf5Provider.tryUnwrapHdf5Group(runGroup);
        if (h5g == null) {
            throw new RuntimeException(
                "REF_DIFF decode requires an HDF5-backed dataset; "
                + "non-HDF5 storage providers are not yet supported.");
        }
        global.thalion.ttio.hdf5.Hdf5File h5File = h5g.owningFile();
        global.thalion.ttio.codecs.ReferenceResolver resolver =
            new global.thalion.ttio.codecs.ReferenceResolver(h5File);

        // Single-chromosome runs only (v1.2 first pass).
        java.util.Set<String> uniqueChroms =
            new java.util.LinkedHashSet<>();
        for (int i = 0; i < index.count(); i++) {
            uniqueChroms.add(index.chromosomeAt(i));
        }
        String chrom;
        if (uniqueChroms.isEmpty()) {
            chrom = "";
        } else if (uniqueChroms.size() > 1) {
            throw new RuntimeException(
                "REF_DIFF v1.2 first pass supports single-chromosome "
                + "runs only; this run carries " + uniqueChroms
                + ". Multi-chromosome support is an M93.X follow-up.");
        } else {
            chrom = uniqueChroms.iterator().next();
        }
        byte[] chromSeq = resolver.resolve(
            hu.header().referenceUri(),
            hu.header().referenceMd5(),
            chrom);

        // Gather per-read positions + cigars for the slice walk.
        long[] positions = new long[index.count()];
        for (int i = 0; i < index.count(); i++) {
            positions[i] = index.positionAt(i);
        }
        java.util.List<String> cigars = allCigars();

        java.util.List<byte[]> perRead = global.thalion.ttio.codecs
            .RefDiff.decode(encoded, cigars, positions, chromSeq);
        // Concat into the flat M82 contract.
        int total = 0;
        for (byte[] p : perRead) total += p.length;
        byte[] out = new byte[total];
        int off = 0;
        for (byte[] p : perRead) {
            System.arraycopy(p, 0, out, off, p.length);
            off += p.length;
        }
        return out;
    }

    /** Return the full list of CIGAR strings for this run. Honours the
     *  M86 Phase C codec dispatch on the cigars channel (RANS /
     *  NAME_TOKENIZED override → uint8 dataset; no override → M82
     *  compound dataset). Caches the result on
     *  {@link #decodedCigars}. */
    private java.util.List<String> allCigars() {
        if (decodedCigars != null) return decodedCigars;
        java.util.List<String> out = new java.util.ArrayList<>(index.count());
        for (int i = 0; i < index.count(); i++) {
            out.add(cigarAt(i));
        }
        // cigarAt() populates decodedCigars when the codec path is hit;
        // the compound-path doesn't set the cache, so set it explicitly
        // here to avoid re-walking on subsequent calls.
        if (decodedCigars == null) decodedCigars = out;
        return decodedCigars;
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
            case INT32 -> {
                // M86 Phase F: mate_info_tlen is signed int32. Same
                // 4-byte LE re-interpret as UINT32; Java's int[] is
                // signed so the bit pattern carries through unchanged.
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

    // ── M86 Phase F: mate_info per-field dispatch ──────────────────

    /** M86 Phase F: true iff {@code signal_channels/mate_info} is a
     *  group (Phase F layout) rather than a dataset (M82 compound
     *  layout). Per Binding Decision §128 / Gotcha §141, dispatch is
     *  on HDF5 link type, NOT on the {@code @compression} attribute
     *  presence on the bare link.
     *
     *  <p>The HDF5 link-type query in Java is
     *  {@code H5.H5Oget_info_by_name(parentId, "mate_info", flags)}
     *  whose returned {@code H5O_info_t.type} field can be compared
     *  to {@link hdf.hdf5lib.HDF5Constants#H5O_TYPE_GROUP} vs
     *  {@link hdf.hdf5lib.HDF5Constants#H5O_TYPE_DATASET}. Because
     *  {@code GenomicRun} is provider-abstract (HDF5 / SQLite /
     *  Zarr / memory), this helper instead uses the StorageGroup
     *  protocol's {@code openGroup} as the link-type query — it
     *  raises an exception when the named child is a dataset (the
     *  HDF5 binding's {@code H5Gopen} call fails with a negative
     *  return on a dataset, surfaced as
     *  {@link global.thalion.ttio.hdf5.Hdf5Errors.GroupOpenException}
     *  by the adapter). This mirrors the Python implementation's
     *  {@code try/except KeyError on h5py.Group} pattern. */
    private boolean isMateInfoSubgroup() {
        ensureSignalChannels();
        if (!signalChannels.hasChild("mate_info")) {
            return false;
        }
        try (StorageGroup g = signalChannels.openGroup("mate_info")) {
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** M86 Phase F: return the mate chromosome at index {@code i},
     *  dispatching on {@code signal_channels/mate_info} link type
     *  (Binding Decision §128).
     *
     *  <ul>
     *    <li><b>M82 compound</b> (no override): COMPOUND[n_reads]
     *        dataset with three fields. Read whole-and-cache via the
     *        existing {@link #compoundRows} helper, then return the
     *        per-read entry.</li>
     *    <li><b>Phase F subgroup</b> (any mate_info_* override): GROUP
     *        containing three child datasets. Decode the chrom child
     *        on first access (cached in
     *        {@code decodedMateInfo["chrom"]} per Binding Decision
     *        §129) and return entry [i].</li>
     *  </ul> */
    private String mateChromAt(int i) {
        if (isMateInfoSubgroup()) {
            return decodeMateChrom().get(i);
        }
        // M82 compound path.
        List<Object[]> rows = compoundRows("mate_info");
        return stringFromCompound(rows.get(i)[0]);
    }

    /** M86 Phase F: return the mate position at index {@code i},
     *  dispatching on the mate_info link type (Binding Decision §128). */
    private long matePosAt(int i) {
        if (isMateInfoSubgroup()) {
            long[] arr = (long[]) decodeMateIntField(
                "pos", global.thalion.ttio.Enums.Precision.INT64);
            return arr[i];
        }
        List<Object[]> rows = compoundRows("mate_info");
        return ((Number) rows.get(i)[1]).longValue();
    }

    /** M86 Phase F: return the template length at index {@code i},
     *  dispatching on the mate_info link type (Binding Decision §128). */
    private int mateTlenAt(int i) {
        if (isMateInfoSubgroup()) {
            int[] arr = (int[]) decodeMateIntField(
                "tlen", global.thalion.ttio.Enums.Precision.INT32);
            return arr[i];
        }
        List<Object[]> rows = compoundRows("mate_info");
        return ((Number) rows.get(i)[2]).intValue();
    }

    /** M86 Phase F: lazily decode the chrom field from the Phase F
     *  subgroup, caching the result in
     *  {@code decodedMateInfo["chrom"]} (Binding Decision §129).
     *  Dispatches on the chrom child dataset's precision and
     *  {@code @compression} attribute:
     *  <ul>
     *    <li>UINT8 + {@code @compression == NAME_TOKENIZED (8)}:
     *        decoded via {@link global.thalion.ttio.codecs.NameTokenizer#decode}.</li>
     *    <li>UINT8 + {@code @compression == RANS_ORDER0|1 (4|5)}:
     *        decoded via M83 rANS, then walked as length-prefix-concat
     *        ({@code varint(len) + ASCII bytes} per chrom).</li>
     *    <li>Compound (no codec): un-overridden field stored at its
     *        natural VL_STRING dtype with HDF5 ZLIB; read whole and
     *        extract the values.</li>
     *  </ul> */
    @SuppressWarnings("unchecked")
    private List<String> decodeMateChrom() {
        Object cached = decodedMateInfo.get("chrom");
        if (cached != null) return (List<String>) cached;

        ensureSignalChannels();
        try (StorageGroup mateGroup = signalChannels.openGroup("mate_info");
             StorageDataset ds = mateGroup.openDataset("chrom")) {
            global.thalion.ttio.Enums.Precision p = ds.precision();
            if (p == global.thalion.ttio.Enums.Precision.UINT8) {
                Object codecAttr = ds.getAttribute("compression");
                long codecId = (codecAttr instanceof Number n)
                    ? n.longValue() : 0L;
                long total = ds.shape()[0];
                byte[] all = (byte[]) ds.readSlice(0L, total);
                List<String> out;
                if (codecId == global.thalion.ttio.Enums.Compression
                        .RANS_ORDER0.ordinal()
                    || codecId == global.thalion.ttio.Enums.Compression
                        .RANS_ORDER1.ordinal()) {
                    byte[] decoded = global.thalion.ttio.codecs
                        .Rans.decode(all);
                    out = decodeLengthPrefixConcatMate(decoded);
                } else if (codecId == global.thalion.ttio.Enums.Compression
                        .NAME_TOKENIZED.ordinal()) {
                    out = global.thalion.ttio.codecs
                        .NameTokenizer.decode(all);
                } else {
                    throw new IllegalStateException(
                        "signal_channel 'mate_info/chrom': @compression="
                        + codecId + " is not a supported TTIO codec id "
                        + "(only RANS_ORDER0 = 4, RANS_ORDER1 = 5, and "
                        + "NAME_TOKENIZED = 8 are recognised for this "
                        + "channel)");
                }
                decodedMateInfo.put("chrom", out);
                return out;
            }
            // Natural-dtype (compound VL_STRING) path — un-overridden
            // field inside the subgroup. Read whole as compound rows.
            @SuppressWarnings("unchecked")
            List<Object[]> rows = (List<Object[]>) ds.readAll();
            List<String> out = new ArrayList<>(rows.size());
            for (Object[] r : rows) out.add(stringFromCompound(r[0]));
            decodedMateInfo.put("chrom", out);
            return out;
        }
    }

    /** M86 Phase F: lazily decode an integer mate field (pos or tlen)
     *  from the Phase F subgroup, caching the result in
     *  {@code decodedMateInfo[name]} (Binding Decision §129).
     *  Dispatches on dataset precision and {@code @compression}:
     *  <ul>
     *    <li>UINT8 + {@code @compression == RANS_ORDER0|1}: decoded
     *        via M83 rANS, then re-interpreted as the natural integer
     *        precision via {@link java.nio.ByteOrder#LITTLE_ENDIAN}.</li>
     *    <li>Natural-dtype (INT64 / INT32, no override): read directly
     *        with the typed reader inside the subgroup.</li>
     *  </ul> */
    private Object decodeMateIntField(String name,
            global.thalion.ttio.Enums.Precision naturalPrecision) {
        Object cached = decodedMateInfo.get(name);
        if (cached != null) return cached;

        ensureSignalChannels();
        try (StorageGroup mateGroup = signalChannels.openGroup("mate_info");
             StorageDataset ds = mateGroup.openDataset(name)) {
            global.thalion.ttio.Enums.Precision p = ds.precision();
            if (p == global.thalion.ttio.Enums.Precision.UINT8) {
                Object codecAttr = ds.getAttribute("compression");
                long codecId = (codecAttr instanceof Number n)
                    ? n.longValue() : 0L;
                if (codecId == global.thalion.ttio.Enums.Compression
                        .RANS_ORDER0.ordinal()
                    || codecId == global.thalion.ttio.Enums.Compression
                        .RANS_ORDER1.ordinal()) {
                    long total = ds.shape()[0];
                    byte[] all = (byte[]) ds.readSlice(0L, total);
                    byte[] decoded = global.thalion.ttio.codecs
                        .Rans.decode(all);
                    Object arr = deserialiseLeBytes(decoded, naturalPrecision);
                    decodedMateInfo.put(name, arr);
                    return arr;
                }
                throw new IllegalStateException(
                    "signal_channel 'mate_info/" + name + "': @compression="
                    + codecId + " is not a supported TTIO codec id for "
                    + "an integer mate field (only RANS_ORDER0 = 4 and "
                    + "RANS_ORDER1 = 5 are recognised)");
            }
            // Natural-dtype path — read the typed dataset directly.
            Object arr = ds.readAll();
            decodedMateInfo.put(name, arr);
            return arr;
        }
    }

    /** M86 Phase F: walk a length-prefix-concat byte buffer back into
     *  a list of ASCII chrom strings. Mirrors {@link #decodeLengthPrefixConcat}
     *  used by the cigars rANS path; kept as a separate copy so the
     *  error messages name the chrom channel. */
    private static List<String> decodeLengthPrefixConcatMate(byte[] buf) {
        List<String> out = new ArrayList<>();
        int offset = 0;
        int n = buf.length;
        long[] tmp = new long[1];
        while (offset < n) {
            offset = readUnsignedVarint(buf, offset, tmp);
            long lengthL = tmp[0];
            if (lengthL < 0 || lengthL > Integer.MAX_VALUE) {
                throw new IllegalArgumentException(
                    "mate_info_chrom rANS stream: length-prefix-concat "
                    + "entry length " + lengthL + " out of int range");
            }
            int length = (int) lengthL;
            if (offset + length > n) {
                throw new IllegalArgumentException(
                    "mate_info_chrom rANS stream: length-prefix-concat "
                    + "entry runs off end of decoded buffer (offset="
                    + offset + ", length=" + length
                    + ", buffer_size=" + n + ")");
            }
            for (int k = 0; k < length; k++) {
                int b = Byte.toUnsignedInt(buf[offset + k]);
                if (b > 0x7F) {
                    throw new IllegalArgumentException(
                        "mate_info_chrom rANS stream: entry contains "
                        + "non-ASCII bytes");
                }
            }
            out.add(new String(buf, offset, length,
                StandardCharsets.US_ASCII));
            offset += length;
        }
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

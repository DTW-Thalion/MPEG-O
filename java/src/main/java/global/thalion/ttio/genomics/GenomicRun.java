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
    // v1.6 (L4): decodedIntChannels removed. The cache supported the
    // intChannelArray helper which read positions/flags/mapping_qualities
    // from signal_channels/ via codec dispatch — but those datasets no
    // longer exist in v1.6 files (they live exclusively in
    // genomic_index/). See docs/format-spec.md §10.7.
    // Task 13 (mate_info v2): lazy decoded triple from inline_v2 blob.
    // Null until first access to a mate field on a v2-layout file.
    private global.thalion.ttio.codecs.MateInfoV2.Triple decodedMateV2 = null;
    // Resolved chrom name table for the v2 path: index → chrom name.
    // Task 13 (ref_diff v2): lazy decoded flat byte stream from the
    // signal_channels/sequences/refdiff_v2 blob. Null until first access
    // on a v1.8-layout file. Separate from decodedByteChannels["sequences"]
    // because the source is a group child, not the sequences dataset.
    private byte[] decodedRefDiffV2 = null;
    // Tri-state cache for isSequencesRefDiffV2(): null = not yet probed,
    // TRUE/FALSE = result. Avoids repeated group-open on every byteChannelSlice call.
    private Boolean sequencesIsV2Cached = null;
    private List<String> mateV2ChromNames = null;

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
        sequencesIsV2Cached = null;
        decodedRefDiffV2 = null;
    }

    // ── Internal helpers ───────────────────────────────────────────

    private void ensureSignalChannels() {
        if (signalChannels == null) {
            signalChannels = runGroup.openGroup("signal_channels");
            // v1.8 (ref_diff v2): sequences may be a GROUP rather than a
            // dataset. Probe and leave sequencesDs null when it's a group;
            // the byteChannelSlice dispatch will route via isSequencesRefDiffV2().
            if (!isSequencesRefDiffV2()) {
                sequencesDs = signalChannels.openDataset("sequences");
            }
            qualitiesDs = signalChannels.openDataset("qualities");
        }
    }

    /** Task 13 (ref_diff v2): return {@code true} iff
     *  {@code signal_channels/sequences} is a GROUP containing a
     *  {@code refdiff_v2} child dataset (v1.8 layout).
     *
     *  <p>Uses a try-openGroup pattern (Binding Decision §128): an
     *  exception from {@code openGroup} means it's a dataset, not a
     *  group. Result is cached in {@link #sequencesIsV2Cached}. */
    private boolean isSequencesRefDiffV2() {
        if (sequencesIsV2Cached != null) return sequencesIsV2Cached;
        // Ensure signal_channels is open before probing.
        if (signalChannels == null) {
            signalChannels = runGroup.openGroup("signal_channels");
        }
        if (!signalChannels.hasChild("sequences")) {
            sequencesIsV2Cached = false;
            return false;
        }
        try (StorageGroup seqGrp = signalChannels.openGroup("sequences")) {
            // It's a group — check for the refdiff_v2 child dataset.
            sequencesIsV2Cached = seqGrp.hasChild("refdiff_v2");
        } catch (Exception e) {
            // sequences is a dataset (v1) — not v2.
            sequencesIsV2Cached = false;
        }
        return sequencesIsV2Cached;
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
        // v1.8 probe: for sequences, check for the group layout first.
        if ("sequences".equals(name) && isSequencesRefDiffV2()) {
            byte[] decoded = decodeRefDiffV2Sequences();
            decodedByteChannels.put(name, decoded);
            byte[] out = new byte[count];
            System.arraycopy(decoded, (int) offset, out, 0, count);
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
        } else if (codecId == global.thalion.ttio.Enums.Compression
                .FQZCOMP_NX16_Z.ordinal()) {
            // M94.Z v1.2: CRAM-mimic rANS-Nx16 quality codec.
            // Wire format carries read_lengths in the header sidecar;
            // revcomp_flags reconstructed from run.flags & 16 (SAM REVERSE).
            int n = index.count();
            int[] revcompFlags = new int[n];
            for (int i = 0; i < n; i++) {
                int f = index.flagsAt(i);
                revcompFlags[i] = ((f & 16) != 0) ? 1 : 0;
            }
            global.thalion.ttio.codecs.FqzcompNx16Z.DecodeResult dr =
                global.thalion.ttio.codecs.FqzcompNx16Z
                    .decode(all, revcompFlags);
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

    // v1.0 reset Phase 2c: decodeRefDiffSequences removed — the v1
    // REF_DIFF reader is no longer supported. Files written with the
    // v1 codec (@compression == 9) raise IllegalStateException at
    // byteChannelSlice (see codec dispatch above).

    /** Task 13 (ref_diff v2): decode the {@code signal_channels/sequences/refdiff_v2}
     *  blob. Returns the concatenated per-read sequence bytes (total_bases long) —
     *  same contract as the M82 sequences channel.
     *
     *  <p>Caches the result in {@link #decodedRefDiffV2}; subsequent calls
     *  return the cached array.
     *
     *  @throws RuntimeException when the native JNI library is unavailable.
     *  @throws global.thalion.ttio.codecs.RefMissingException when the reference
     *      cannot be resolved. */
    @SuppressWarnings("unchecked")
    private byte[] decodeRefDiffV2Sequences() {
        if (decodedRefDiffV2 != null) return decodedRefDiffV2;

        if (!global.thalion.ttio.codecs.RefDiffV2.isAvailable()) {
            throw new RuntimeException(
                "REF_DIFF_V2 decode requires the native JNI library "
                + "(libttio_rans). Set -Djava.library.path to the "
                + "directory containing the library.");
        }

        ensureSignalChannels();
        byte[] blob;
        try (StorageGroup seqGrp = signalChannels.openGroup("sequences");
             StorageDataset blobDs = seqGrp.openDataset("refdiff_v2")) {
            // Validate @compression attribute.
            Object codecAttr = blobDs.getAttribute("compression");
            long codecId = (codecAttr instanceof Number n) ? n.longValue() : -1L;
            if (codecId != global.thalion.ttio.Enums.Compression.REF_DIFF_V2.ordinal()) {
                throw new IllegalStateException(
                    "signal_channels/sequences/refdiff_v2: @compression="
                    + codecId + ", expected REF_DIFF_V2 = "
                    + global.thalion.ttio.Enums.Compression.REF_DIFF_V2.ordinal());
            }
            long total = blobDs.shape()[0];
            blob = (byte[]) blobDs.readSlice(0L, total);
        }

        // Parse the outer header to extract reference_uri and reference_md5.
        global.thalion.ttio.codecs.RefDiffV2.BlobHeader header =
            global.thalion.ttio.codecs.RefDiffV2.parseBlobHeader(blob);

        // Resolve reference via ReferenceResolver (same chain as v1 REF_DIFF).
        global.thalion.ttio.hdf5.Hdf5Group h5g = global.thalion.ttio.providers
            .Hdf5Provider.tryUnwrapHdf5Group(runGroup);
        if (h5g == null) {
            throw new RuntimeException(
                "REF_DIFF_V2 decode requires an HDF5-backed dataset; "
                + "non-HDF5 storage providers are not yet supported.");
        }
        global.thalion.ttio.hdf5.Hdf5File h5File = h5g.owningFile();
        global.thalion.ttio.codecs.ReferenceResolver resolver =
            new global.thalion.ttio.codecs.ReferenceResolver(h5File);

        // Single-chromosome runs only (v1.8 first pass).
        java.util.Set<String> uniqueChroms = new java.util.LinkedHashSet<>();
        for (int i = 0; i < index.count(); i++) {
            uniqueChroms.add(index.chromosomeAt(i));
        }
        String chrom;
        if (uniqueChroms.isEmpty()) {
            chrom = "";
        } else if (uniqueChroms.size() > 1) {
            throw new RuntimeException(
                "REF_DIFF_V2 v1.8 supports single-chromosome runs only; "
                + "this run carries " + uniqueChroms + ".");
        } else {
            chrom = uniqueChroms.iterator().next();
        }

        byte[] chromSeq = resolver.resolve(
            header.referenceUri(),
            header.referenceMd5(),
            chrom);

        // Decode via the native JNI library.
        int n = index.count();
        long[] positions = new long[n];
        for (int i = 0; i < n; i++) positions[i] = index.positionAt(i);
        String[] cigarArr = allCigars().toArray(new String[0]);
        long totalBases = 0;
        for (int i = 0; i < n; i++) totalBases += index.lengthAt(i);

        global.thalion.ttio.codecs.RefDiffV2.Pair result =
            global.thalion.ttio.codecs.RefDiffV2.decode(
                blob, positions, cigarArr, chromSeq,
                n, totalBases);

        decodedRefDiffV2 = result.sequences;
        return decodedRefDiffV2;
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

    /** v1.0 reset Phase 2c: return the read name at index {@code i}.
     *
     *  <p>Only the NAME_TOKENIZED_V2 (codec id 15) layout is supported
     *  in v1.0+. Legacy v1 layouts raise {@code IllegalStateException}:
     *  <ul>
     *    <li>flat uint8 + {@code @compression == NAME_TOKENIZED (8)} →
     *        v1 codec rejected, see message.</li>
     *    <li>VL-string compound dataset (M82 layout) → also rejected;
     *        the v1.0 writer produces flat uint8 v2 only.</li>
     *  </ul>
     *
     *  <p>If {@code readCount == 0} the writer emits an empty group
     *  (no child datasets); this method short-circuits there. */
    private String readNameAt(int i) {
        if (index.count() == 0) {
            // Defensive: read at index 0 on an empty run is an
            // out-of-range error caught upstream; return-empty-string
            // here keeps the codepath safe.
            return "";
        }
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
                        .NAME_TOKENIZED_V2.ordinal()) {
                    // v1.8 #11 ch3: name_tok_v2 codec output (NTK2 magic).
                    long total = ds.shape()[0];
                    byte[] all = (byte[]) ds.readSlice(0L, total);
                    decodedReadNames = global.thalion.ttio.codecs
                        .NameTokenizerV2.decode(all);
                    return decodedReadNames.get(i);
                }
                throw new IllegalStateException(
                    "signal_channel 'read_names': @compression="
                    + codecId + " is not a supported TTIO codec id "
                    + "for the read_names channel (only "
                    + "NAME_TOKENIZED_V2 = 15 is recognised in v1.0+)");
            }
        }
        // Compound (M82 VL_STRING) path was removed in Phase 2c — the
        // v1.0+ writer always emits a flat uint8 dataset (or an empty
        // group for readCount == 0). Files with the M82 compound were
        // produced by older writers; reject with a clear message.
        throw new IllegalStateException(
            "signal_channels/read_names is a compound (VL_STRING) "
            + "dataset — that legacy M82 layout was removed in "
            + "Phase 2c (v1.0 reset). Re-encode the file with v1.0+ "
            + "which writes read_names as NAME_TOKENIZED_V2 (codec "
            + "id 15) on a flat uint8 dataset.");
    }

    /** M86 Phase C: return the cigar string at index {@code i},
     *  dispatching on dataset shape (Binding Decisions §120-§123).
     *
     *  <p>Two on-disk layouts:
     *  <ul>
     *    <li><b>M82 compound</b> (no override): VL_STRING-in-compound
     *        dataset, read whole-and-cache via {@link #compoundRows}.</li>
     *    <li><b>rANS codec</b> (override active): flat 1-D uint8
     *        dataset. The whole channel is read, decoded once, and
     *        cached as a {@code List<String>} on this instance per
     *        Binding Decision §123. The decoded byte buffer is a
     *        length-prefix-concat sequence ({@code varint(len) + bytes}
     *        per CIGAR); walk the buffer to reconstruct the list.</li>
     *  </ul>
     */
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
                throw new IllegalStateException(
                    "signal_channel 'cigars': @compression="
                    + codecId + " is not a supported TTIO codec id "
                    + "for the cigars channel (only RANS_ORDER0 = 4 "
                    + "and RANS_ORDER1 = 5 are recognised in v1.0+)");
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

    // ── M86 Phase F: mate_info per-field dispatch ──────────────────

    /** Task 13 (mate_info v2): true iff
     *  {@code signal_channels/mate_info/inline_v2} exists (v1.7 layout).
     *  Called first in the mate accessor dispatch chain; when true,
     *  {@link #_decodeMateV2()} is used instead of the Phase F subgroup
     *  or M82 compound paths. */
    private boolean isMateInfoInlineV2() {
        ensureSignalChannels();
        if (!signalChannels.hasChild("mate_info")) return false;
        try (StorageGroup mateGrp = signalChannels.openGroup("mate_info")) {
            return mateGrp.hasChild("inline_v2");
        } catch (Exception e) {
            return false;
        }
    }

    /** Task 13: lazily decode the inline_v2 blob + chrom_names sidecar.
     *  Caches the result in {@link #decodedMateV2} and
     *  {@link #mateV2ChromNames}. */
    @SuppressWarnings("unchecked")
    private void _decodeMateV2() {
        if (decodedMateV2 != null) return;
        ensureSignalChannels();
        try (StorageGroup mateGrp = signalChannels.openGroup("mate_info")) {
            // Read the blob.
            byte[] blob;
            try (StorageDataset blobDs = mateGrp.openDataset("inline_v2")) {
                long total = blobDs.shape()[0];
                blob = (byte[]) blobDs.readSlice(0L, total);
            }
            // Read chrom_names sidecar.
            List<Object[]> nameRows;
            try (StorageDataset nameDs = mateGrp.openDataset("chrom_names")) {
                nameRows = (List<Object[]>) nameDs.readAll();
            }
            List<String> chromTable = new ArrayList<>(nameRows.size());
            for (Object[] row : nameRows) {
                Object v = row[0];
                if (v instanceof byte[] b) {
                    chromTable.add(new String(b, StandardCharsets.UTF_8));
                } else {
                    chromTable.add(v == null ? "" : v.toString());
                }
            }
            mateV2ChromNames = chromTable;
            // Build own_chrom_ids and own_positions from the index.
            int n = index.count();
            // Resolve own chrom_ids: rebuild the encounter-order table
            // from index.chromosomeAt() in the same order as the writer.
            // We need the actual uint16 ids, which the writer derived
            // from the chromToId map. The chrom_names sidecar begins
            // with own chroms in encounter order (writer guarantees this).
            // Re-derive the id-per-read from the sidecar table.
            java.util.LinkedHashMap<String, Integer> nameToId =
                new java.util.LinkedHashMap<>();
            for (int j = 0; j < chromTable.size(); j++) {
                nameToId.put(chromTable.get(j), j);
            }
            short[] ownChromIds = new short[n];
            long[]  ownPositions = new long[n];
            for (int i = 0; i < n; i++) {
                String chr = index.chromosomeAt(i);
                Integer id = nameToId.get(chr);
                ownChromIds[i] = (id == null) ? (short) 0xFFFF
                               : id.shortValue();
                ownPositions[i] = index.positionAt(i);
            }
            decodedMateV2 = global.thalion.ttio.codecs.MateInfoV2.decode(
                blob, ownChromIds, ownPositions, n);
        }
    }

    // v1.0 reset Phase 2c: isMateInfoSubgroup removed — the M86
    // Phase F per-field subgroup reader is no longer reached. The
    // mate accessors below short-circuit to inline_v2 or throw.

    /** v1.0 reset Phase 2c: return the mate chromosome at index
     *  {@code i}. Only the inline_v2 blob layout is supported now;
     *  the M86 Phase F per-field subgroup and the M82 compound layout
     *  raise {@code IllegalStateException}. */
    private String mateChromAt(int i) {
        if (isMateInfoInlineV2()) {
            _decodeMateV2();
            int mateChromId = decodedMateV2.mateChromIds[i];
            if (mateChromId == -1) return "*";
            if (mateV2ChromNames != null && mateChromId < mateV2ChromNames.size()) {
                return mateV2ChromNames.get(mateChromId);
            }
            return "*";  // defensive fallback
        }
        throw mateInfoLegacyLayoutError();
    }

    /** v1.0 reset Phase 2c: return the mate position at index
     *  {@code i}. Inline_v2 only — see {@link #mateChromAt}. */
    private long matePosAt(int i) {
        if (isMateInfoInlineV2()) {
            _decodeMateV2();
            return decodedMateV2.matePositions[i];
        }
        throw mateInfoLegacyLayoutError();
    }

    /** v1.0 reset Phase 2c: return the template length at index
     *  {@code i}. Inline_v2 only — see {@link #mateChromAt}. */
    private int mateTlenAt(int i) {
        if (isMateInfoInlineV2()) {
            _decodeMateV2();
            return decodedMateV2.templateLengths[i];
        }
        throw mateInfoLegacyLayoutError();
    }

    /** Common error for legacy mate_info layouts (M86 Phase F
     *  per-field subgroup or M82 compound). Both were removed in
     *  Phase 2c; only the v2 inline_v2 blob is read. */
    private static IllegalStateException mateInfoLegacyLayoutError() {
        return new IllegalStateException(
            "signal_channels/mate_info legacy layout (M86 Phase F "
            + "per-field subgroup or M82 compound dataset) is no "
            + "longer supported in v1.0; this file was written with "
            + "an older TTI-O version. Re-encode with v1.0+ which "
            + "uses MATE_INLINE_V2 (codec id 13) at "
            + "signal_channels/mate_info/inline_v2.");
    }

    // v1.0 reset Phase 2c: decodeMateChrom + decodeMateIntField +
    // decodeLengthPrefixConcatMate removed — the M86 Phase F per-
    // field subgroup readers are gone. Only the v2 inline_v2 blob
    // path survives via _decodeMateV2.

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

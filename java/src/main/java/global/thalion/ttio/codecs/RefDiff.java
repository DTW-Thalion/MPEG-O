/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * REF_DIFF — reference-based sequence-diff codec (M93 v1.2).
 *
 * <p>Clean-room Java port of the Python reference implementation
 * ({@code python/src/ttio/codecs/ref_diff.py}). Wire format and
 * algorithm documented in
 * {@code docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md}
 * §3 (M93) and {@code docs/codecs/ref_diff.md}. Codec id is
 * {@link global.thalion.ttio.Enums.Compression#REF_DIFF} = 9.
 *
 * <p>REF_DIFF is <b>context-aware</b>: encode/decode receives
 * {@code positions}, {@code cigars}, and a reference sequence alongside
 * the {@code sequences} byte stream. The pipeline plumbing is the
 * responsibility of the M86 layer in
 * {@link global.thalion.ttio.SpectralDataset}; this class exposes pure
 * functions only.
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Python: {@code ttio.codecs.ref_diff}</li>
 *   <li>Objective-C: {@code TTIORefDiff}</li>
 * </ul>
 */
public final class RefDiff {

    // ── Wire-format constants ───────────────────────────────────────

    /** Magic prefix on every REF_DIFF stream. */
    public static final byte[] MAGIC = new byte[]{'R', 'D', 'I', 'F'};

    /** Codec wire-format version. */
    public static final int VERSION = 1;

    /** Header fixed prefix (everything before the variable-length URI):
     *  magic(4) + version(1) + reserved(3) + num_slices(4) +
     *  total_reads(8) + reference_md5(16) + reference_uri_len(2) =
     *  38 bytes. */
    public static final int HEADER_FIXED_SIZE = 38;

    /** Slice index entry: body_offset(8) + body_length(4) +
     *  first_position(8) + last_position(8) + num_reads(4) = 32 bytes. */
    public static final int SLICE_INDEX_ENTRY_SIZE = 32;

    /** Default slice size — CRAM-aligned, 10K reads per slice. */
    public static final int SLICE_SIZE_DEFAULT = 10_000;

    /** Matches one CIGAR operation: digits followed by op letter. */
    private static final Pattern CIGAR_OP = Pattern.compile("(\\d+)([MIDNSHPX=])");

    private RefDiff() {
        // Utility class — non-instantiable.
    }

    // ── Records ──────────────────────────────────────────────────────

    /**
     * REF_DIFF wire-format header (38 + len(referenceUri) bytes).
     *
     * @param numSlices    uint32 — number of encoded slices.
     * @param totalReads   uint64 — total read count across all slices.
     * @param referenceMd5 16-byte md5 digest of the canonical reference.
     * @param referenceUri UTF-8; the BAM header's @SQ M5 lookup key.
     */
    public record CodecHeader(
        int numSlices,
        long totalReads,
        byte[] referenceMd5,
        String referenceUri
    ) {
        public CodecHeader {
            if (referenceMd5 == null || referenceMd5.length != 16) {
                throw new IllegalArgumentException(
                    "referenceMd5 must be 16 bytes, got "
                    + (referenceMd5 == null ? "null" : referenceMd5.length));
            }
            if (referenceUri == null) {
                throw new IllegalArgumentException("referenceUri must not be null");
            }
            byte[] uriBytes = referenceUri.getBytes(StandardCharsets.UTF_8);
            if (uriBytes.length > 0xFFFF) {
                throw new IllegalArgumentException(
                    "referenceUri too long (" + uriBytes.length
                    + " bytes UTF-8 > 65535)");
            }
        }
    }

    /**
     * Per-slice index entry (32 bytes).
     *
     * @param bodyOffset    uint64 — offset relative to the slice-bodies block.
     * @param bodyLength    uint32 — length of this slice's encoded body.
     * @param firstPosition int64  — first read's 1-based reference position.
     * @param lastPosition  int64  — last read's 1-based reference position.
     * @param numReads      uint32 — read count in this slice.
     */
    public record SliceIndexEntry(
        long bodyOffset,
        int bodyLength,
        long firstPosition,
        long lastPosition,
        int numReads
    ) { }

    /**
     * Output of walking one read's CIGAR against the reference.
     *
     * <p>{@code mOpFlagBits[k] = 0} means the read base matches the
     * reference at the k-th M-op base; {@code = 1} means substitution
     * (the actual base lives in {@code substitutionBases} at the
     * corresponding running index).
     */
    public record ReadWalkResult(
        int[] mOpFlagBits,
        byte[] substitutionBases,
        byte[] insertionBases,
        byte[] softclipBases
    ) { }

    // ── Header pack/unpack ──────────────────────────────────────────

    /** Serialise {@code h} to the on-wire byte sequence
     *  ({@code 38 + len(referenceUri.utf8)} bytes). */
    public static byte[] packCodecHeader(CodecHeader h) {
        byte[] uriBytes = h.referenceUri().getBytes(StandardCharsets.UTF_8);
        ByteBuffer bb = ByteBuffer
            .allocate(HEADER_FIXED_SIZE + uriBytes.length)
            .order(ByteOrder.LITTLE_ENDIAN);
        bb.put(MAGIC);
        bb.put((byte) VERSION);
        bb.put(new byte[]{0, 0, 0});       // 3 reserved bytes
        bb.putInt(h.numSlices());
        bb.putLong(h.totalReads());
        bb.put(h.referenceMd5());
        bb.putShort((short) uriBytes.length);
        bb.put(uriBytes);
        return bb.array();
    }

    /** Result of {@link #unpackCodecHeader}: header + total bytes consumed
     *  (header fixed + URI). */
    public record HeaderUnpack(CodecHeader header, int bytesConsumed) { }

    /** Inverse of {@link #packCodecHeader}. */
    public static HeaderUnpack unpackCodecHeader(byte[] blob) {
        if (blob == null) {
            throw new IllegalArgumentException("blob must not be null");
        }
        if (blob.length < HEADER_FIXED_SIZE) {
            throw new IllegalArgumentException(
                "REF_DIFF header too short: " + blob.length + " bytes");
        }
        for (int i = 0; i < 4; i++) {
            if (blob[i] != MAGIC[i]) {
                throw new IllegalArgumentException(
                    "REF_DIFF bad magic: 0x" + bytesToHex(blob, 0, 4)
                    + ", expected 'RDIF'");
            }
        }
        int version = Byte.toUnsignedInt(blob[4]);
        if (version != VERSION) {
            throw new IllegalArgumentException(
                "REF_DIFF unsupported version: " + version);
        }
        ByteBuffer bb = ByteBuffer.wrap(blob).order(ByteOrder.LITTLE_ENDIAN);
        int numSlices = bb.getInt(8);
        long totalReads = bb.getLong(12);
        byte[] md5 = new byte[16];
        System.arraycopy(blob, 20, md5, 0, 16);
        int uriLen = Short.toUnsignedInt(bb.getShort(36));
        int end = HEADER_FIXED_SIZE + uriLen;
        if (blob.length < end) {
            throw new IllegalArgumentException(
                "REF_DIFF header truncated in reference_uri");
        }
        String uri = new String(blob, HEADER_FIXED_SIZE, uriLen,
            StandardCharsets.UTF_8);
        return new HeaderUnpack(
            new CodecHeader(numSlices, totalReads, md5, uri), end);
    }

    /** Serialise a slice-index entry (32 bytes). */
    public static byte[] packSliceIndexEntry(SliceIndexEntry e) {
        ByteBuffer bb = ByteBuffer
            .allocate(SLICE_INDEX_ENTRY_SIZE)
            .order(ByteOrder.LITTLE_ENDIAN);
        bb.putLong(e.bodyOffset());
        bb.putInt(e.bodyLength());
        bb.putLong(e.firstPosition());
        bb.putLong(e.lastPosition());
        bb.putInt(e.numReads());
        return bb.array();
    }

    /** Inverse of {@link #packSliceIndexEntry}. */
    public static SliceIndexEntry unpackSliceIndexEntry(byte[] blob) {
        if (blob == null || blob.length != SLICE_INDEX_ENTRY_SIZE) {
            throw new IllegalArgumentException(
                "slice index entry must be " + SLICE_INDEX_ENTRY_SIZE
                + " bytes, got " + (blob == null ? "null" : blob.length));
        }
        ByteBuffer bb = ByteBuffer.wrap(blob).order(ByteOrder.LITTLE_ENDIAN);
        long bodyOffset = bb.getLong();
        int  bodyLength = bb.getInt();
        long firstPosition = bb.getLong();
        long lastPosition  = bb.getLong();
        int  numReads = bb.getInt();
        return new SliceIndexEntry(bodyOffset, bodyLength,
            firstPosition, lastPosition, numReads);
    }

    // ── CIGAR walker ────────────────────────────────────────────────

    /** Walk one read's CIGAR against the reference and emit a diff record.
     *
     *  <p>Mirror of Python's {@code walk_read_against_reference}. */
    public static ReadWalkResult walkReadAgainstReference(
        byte[] sequence, String cigar, long position,
        byte[] referenceChromSeq) {
        if (cigar == null || cigar.isEmpty() || "*".equals(cigar)) {
            throw new IllegalArgumentException(
                "REF_DIFF cannot encode unmapped reads (cigar='*' or empty); "
                + "route through BASE_PACK on a separate sub-channel");
        }

        List<Integer> flagBits = new ArrayList<>();
        java.io.ByteArrayOutputStream subBuf  = new java.io.ByteArrayOutputStream();
        java.io.ByteArrayOutputStream insBuf  = new java.io.ByteArrayOutputStream();
        java.io.ByteArrayOutputStream softBuf = new java.io.ByteArrayOutputStream();

        int seqI = 0;
        long refI = position - 1L;  // 1-based → 0-based

        Matcher m = CIGAR_OP.matcher(cigar);
        while (m.find()) {
            int length = Integer.parseInt(m.group(1));
            char op = m.group(2).charAt(0);
            switch (op) {
                case 'M', '=', 'X' -> {
                    for (int k = 0; k < length; k++) {
                        byte readBase = sequence[seqI + k];
                        byte refBase  = referenceChromSeq[(int) (refI + k)];
                        if (readBase == refBase) {
                            flagBits.add(0);
                        } else {
                            flagBits.add(1);
                            subBuf.write(readBase & 0xFF);
                        }
                    }
                    seqI += length;
                    refI += length;
                }
                case 'I' -> {
                    insBuf.write(sequence, seqI, length);
                    seqI += length;
                }
                case 'S' -> {
                    softBuf.write(sequence, seqI, length);
                    seqI += length;
                }
                case 'D', 'N' -> refI += length;
                case 'H', 'P' -> { /* no payload */ }
                default -> throw new IllegalArgumentException(
                    "unsupported CIGAR op: " + op);
            }
        }

        int[] flagArr = new int[flagBits.size()];
        for (int i = 0; i < flagArr.length; i++) flagArr[i] = flagBits.get(i);
        return new ReadWalkResult(flagArr,
            subBuf.toByteArray(), insBuf.toByteArray(), softBuf.toByteArray());
    }

    /** Reconstruct a read sequence from its diff record + CIGAR + reference.
     *  Inverse of {@link #walkReadAgainstReference}. */
    public static byte[] reconstructReadFromWalk(
        ReadWalkResult walk, String cigar, long position,
        byte[] referenceChromSeq) {
        if (cigar == null || cigar.isEmpty() || "*".equals(cigar)) {
            throw new IllegalArgumentException("cannot reconstruct unmapped read");
        }
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        int flagI = 0;
        int subI  = 0;
        int insI  = 0;
        int softI = 0;
        long refI = position - 1L;

        Matcher m = CIGAR_OP.matcher(cigar);
        while (m.find()) {
            int length = Integer.parseInt(m.group(1));
            char op = m.group(2).charAt(0);
            switch (op) {
                case 'M', '=', 'X' -> {
                    for (int k = 0; k < length; k++) {
                        if (walk.mOpFlagBits()[flagI] == 0) {
                            out.write(referenceChromSeq[(int) (refI + k)] & 0xFF);
                        } else {
                            out.write(walk.substitutionBases()[subI] & 0xFF);
                            subI++;
                        }
                        flagI++;
                    }
                    refI += length;
                }
                case 'I' -> {
                    out.write(walk.insertionBases(), insI, length);
                    insI += length;
                }
                case 'S' -> {
                    out.write(walk.softclipBases(), softI, length);
                    softI += length;
                }
                case 'D', 'N' -> refI += length;
                case 'H', 'P' -> { /* no payload */ }
                default -> throw new IllegalArgumentException(
                    "unsupported CIGAR op: " + op);
            }
        }
        // Sanity: cursors must be exhausted.
        if (flagI != walk.mOpFlagBits().length
            || subI  != walk.substitutionBases().length
            || insI  != walk.insertionBases().length
            || softI != walk.softclipBases().length) {
            throw new IllegalStateException(
                "reconstruct cursor mismatch — flags=" + flagI
                + "/" + walk.mOpFlagBits().length
                + " sub=" + subI + "/" + walk.substitutionBases().length
                + " ins=" + insI + "/" + walk.insertionBases().length
                + " soft=" + softI + "/" + walk.softclipBases().length);
        }
        return out.toByteArray();
    }

    // ── Bit-pack/unpack ─────────────────────────────────────────────

    /** Pack one read's diff record into the wire bitstream.
     *
     *  <p>Layout:
     *  <ol>
     *    <li>For each M-op flag bit, append the bit MSB-first within byte;
     *        after a {@code 1} flag, append the corresponding substitution
     *        byte's 8 bits MSB-first.</li>
     *    <li>Pad bits to byte boundary with zeros.</li>
     *    <li>Then I-op bases verbatim (whole bytes).</li>
     *    <li>Then S-op bases verbatim.</li>
     *  </ol>
     */
    public static byte[] packReadDiffBitstream(ReadWalkResult walk) {
        // Build a bit list, then pack MSB-first into bytes.
        List<Integer> bits = new ArrayList<>();
        int subI = 0;
        for (int flag : walk.mOpFlagBits()) {
            bits.add(flag);
            if (flag == 1) {
                int subByte = walk.substitutionBases()[subI] & 0xFF;
                subI++;
                for (int shift = 7; shift >= 0; shift--) {
                    bits.add((subByte >>> shift) & 1);
                }
            }
        }
        // Pad to byte boundary.
        while (bits.size() % 8 != 0) bits.add(0);

        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        for (int i = 0; i < bits.size(); i += 8) {
            int b = 0;
            for (int j = 0; j < 8; j++) {
                b = (b << 1) | bits.get(i + j);
            }
            out.write(b);
        }
        out.write(walk.insertionBases(), 0, walk.insertionBases().length);
        out.write(walk.softclipBases(), 0, walk.softclipBases().length);
        return out.toByteArray();
    }

    /** Result of {@link #unpackReadDiffBitstreamWithConsumed}: walk record
     *  plus the total bytes consumed from {@code blob}. */
    public record BitstreamUnpack(ReadWalkResult walk, int bytesConsumed) { }

    /** Inverse of {@link #packReadDiffBitstream}. Caller supplies M-op
     *  count + I/S-op lengths recovered from the cigar channel. */
    public static ReadWalkResult unpackReadDiffBitstream(
        byte[] blob, int numMOps, int insLength, int softclipLength) {
        return unpackReadDiffBitstreamWithConsumed(
            blob, 0, numMOps, insLength, softclipLength).walk();
    }

    /** Variant of {@link #unpackReadDiffBitstream} that also reports the
     *  total bytes consumed (used by {@link #decodeSlice}). */
    public static BitstreamUnpack unpackReadDiffBitstreamWithConsumed(
        byte[] blob, int offset,
        int numMOps, int insLength, int softclipLength) {
        int[] flagBits = new int[numMOps];
        byte[] subBuf = new byte[numMOps];  // upper bound; may be smaller
        int subCount = 0;
        int bitCursor = 0;
        for (int k = 0; k < numMOps; k++) {
            int byteIdx = bitCursor / 8;
            int bitOff  = bitCursor % 8;
            int flag = (Byte.toUnsignedInt(blob[offset + byteIdx])
                        >>> (7 - bitOff)) & 1;
            flagBits[k] = flag;
            bitCursor++;
            if (flag == 1) {
                int subByte = 0;
                for (int b = 0; b < 8; b++) {
                    int bi = bitCursor / 8;
                    int bo = bitCursor % 8;
                    subByte = (subByte << 1)
                        | ((Byte.toUnsignedInt(blob[offset + bi])
                            >>> (7 - bo)) & 1);
                    bitCursor++;
                }
                subBuf[subCount++] = (byte) subByte;
            }
        }
        int bytesConsumedBits = (bitCursor + 7) / 8;
        byte[] sub = new byte[subCount];
        System.arraycopy(subBuf, 0, sub, 0, subCount);
        byte[] ins = new byte[insLength];
        System.arraycopy(blob, offset + bytesConsumedBits, ins, 0, insLength);
        byte[] soft = new byte[softclipLength];
        System.arraycopy(blob, offset + bytesConsumedBits + insLength,
            soft, 0, softclipLength);
        ReadWalkResult walk = new ReadWalkResult(flagBits, sub, ins, soft);
        return new BitstreamUnpack(walk,
            bytesConsumedBits + insLength + softclipLength);
    }

    // ── Per-slice encode/decode ─────────────────────────────────────

    private static int[] cigarOpLengths(String cigar) {
        int mCount = 0, iTotal = 0, sTotal = 0;
        Matcher m = CIGAR_OP.matcher(cigar);
        while (m.find()) {
            int n = Integer.parseInt(m.group(1));
            char op = m.group(2).charAt(0);
            switch (op) {
                case 'M', '=', 'X' -> mCount += n;
                case 'I' -> iTotal += n;
                case 'S' -> sTotal += n;
                default -> { /* D/N/H/P consume no bits/bytes here */ }
            }
        }
        return new int[]{mCount, iTotal, sTotal};
    }

    /** Encode a slice of up to {@link #SLICE_SIZE_DEFAULT} reads into a
     *  rANS-compressed byte blob. */
    public static byte[] encodeSlice(
        List<byte[]> sequences, List<String> cigars, long[] positions,
        byte[] referenceChromSeq) {
        java.io.ByteArrayOutputStream raw = new java.io.ByteArrayOutputStream();
        for (int i = 0; i < sequences.size(); i++) {
            ReadWalkResult walk = walkReadAgainstReference(
                sequences.get(i), cigars.get(i), positions[i],
                referenceChromSeq);
            byte[] packed = packReadDiffBitstream(walk);
            raw.write(packed, 0, packed.length);
        }
        return Rans.encode(raw.toByteArray(), 0);
    }

    /** Inverse of {@link #encodeSlice}. */
    public static List<byte[]> decodeSlice(
        byte[] encoded, List<String> cigars, long[] positions,
        byte[] referenceChromSeq, int numReads) {
        if (numReads != cigars.size() || numReads != positions.length) {
            throw new IllegalArgumentException(
                "cigars/positions count must equal num_reads");
        }
        byte[] raw = Rans.decode(encoded);
        List<byte[]> out = new ArrayList<>(numReads);
        int cursor = 0;
        for (int i = 0; i < numReads; i++) {
            int[] lens = cigarOpLengths(cigars.get(i));
            BitstreamUnpack u = unpackReadDiffBitstreamWithConsumed(
                raw, cursor, lens[0], lens[1], lens[2]);
            cursor += u.bytesConsumed();
            out.add(reconstructReadFromWalk(u.walk(), cigars.get(i),
                positions[i], referenceChromSeq));
        }
        return out;
    }

    // ── Top-level encode/decode ─────────────────────────────────────

    /** Top-level REF_DIFF encoder. */
    public static byte[] encode(
        List<byte[]> sequences, List<String> cigars, long[] positions,
        byte[] referenceChromSeq, byte[] referenceMd5, String referenceUri) {
        return encode(sequences, cigars, positions,
            referenceChromSeq, referenceMd5, referenceUri,
            SLICE_SIZE_DEFAULT);
    }

    /** Top-level REF_DIFF encoder with explicit slice size. */
    public static byte[] encode(
        List<byte[]> sequences, List<String> cigars, long[] positions,
        byte[] referenceChromSeq, byte[] referenceMd5, String referenceUri,
        int sliceSize) {
        if (sequences.size() != cigars.size()
            || sequences.size() != positions.length) {
            throw new IllegalArgumentException(
                "sequences/cigars/positions length mismatch");
        }
        int nReads = sequences.size();
        int nSlices = nReads == 0 ? 0
            : (nReads + sliceSize - 1) / sliceSize;
        List<byte[]> sliceBlobs = new ArrayList<>(nSlices);
        List<SliceIndexEntry> sliceIndex = new ArrayList<>(nSlices);
        long bodyOffset = 0L;
        for (int s = 0; s < nSlices; s++) {
            int lo = s * sliceSize;
            int hi = Math.min(lo + sliceSize, nReads);
            int n = hi - lo;
            // Sub-slice the per-read inputs.
            List<byte[]> seqSlice = sequences.subList(lo, hi);
            List<String> cigSlice = cigars.subList(lo, hi);
            long[] posSlice = new long[n];
            System.arraycopy(positions, lo, posSlice, 0, n);
            byte[] body = encodeSlice(seqSlice, cigSlice, posSlice, referenceChromSeq);
            sliceIndex.add(new SliceIndexEntry(
                bodyOffset, body.length,
                positions[lo], positions[hi - 1], n));
            sliceBlobs.add(body);
            bodyOffset += body.length;
        }

        byte[] header = packCodecHeader(new CodecHeader(
            nSlices, (long) nReads, referenceMd5, referenceUri));
        // Sum lengths for the final buffer.
        int total = header.length
            + nSlices * SLICE_INDEX_ENTRY_SIZE
            + (int) bodyOffset;
        byte[] out = new byte[total];
        int off = 0;
        System.arraycopy(header, 0, out, off, header.length);
        off += header.length;
        for (SliceIndexEntry e : sliceIndex) {
            byte[] entry = packSliceIndexEntry(e);
            System.arraycopy(entry, 0, out, off, entry.length);
            off += entry.length;
        }
        for (byte[] body : sliceBlobs) {
            System.arraycopy(body, 0, out, off, body.length);
            off += body.length;
        }
        return out;
    }

    /** Top-level REF_DIFF decoder. */
    public static List<byte[]> decode(
        byte[] encoded, List<String> cigars, long[] positions,
        byte[] referenceChromSeq) {
        HeaderUnpack hu = unpackCodecHeader(encoded);
        int cursor = hu.bytesConsumed();
        List<SliceIndexEntry> entries = new ArrayList<>(hu.header().numSlices());
        for (int i = 0; i < hu.header().numSlices(); i++) {
            byte[] entryBytes = new byte[SLICE_INDEX_ENTRY_SIZE];
            System.arraycopy(encoded, cursor, entryBytes, 0,
                SLICE_INDEX_ENTRY_SIZE);
            entries.add(unpackSliceIndexEntry(entryBytes));
            cursor += SLICE_INDEX_ENTRY_SIZE;
        }
        int bodiesStart = cursor;

        List<byte[]> out = new ArrayList<>();
        int readCursor = 0;
        for (SliceIndexEntry entry : entries) {
            int bodyStart = bodiesStart + (int) entry.bodyOffset();
            byte[] body = new byte[entry.bodyLength()];
            System.arraycopy(encoded, bodyStart, body, 0, entry.bodyLength());
            int n = entry.numReads();
            List<String> cigSlice = cigars.subList(readCursor, readCursor + n);
            long[] posSlice = new long[n];
            System.arraycopy(positions, readCursor, posSlice, 0, n);
            List<byte[]> sliceSeqs = decodeSlice(body, cigSlice, posSlice,
                referenceChromSeq, n);
            out.addAll(sliceSeqs);
            readCursor += n;
        }
        return out;
    }

    // ── Internal helpers ────────────────────────────────────────────

    private static String bytesToHex(byte[] buf, int off, int len) {
        StringBuilder sb = new StringBuilder(len * 2);
        for (int i = 0; i < len; i++) {
            sb.append(String.format("%02x", buf[off + i] & 0xFF));
        }
        return sb.toString();
    }
}

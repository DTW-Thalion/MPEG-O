package global.thalion.ttio.genomics;

import global.thalion.ttio.Enums;
import global.thalion.ttio.providers.StorageDataset;
import global.thalion.ttio.providers.StorageGroup;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

/**
 * Packed storage for embedded reference chromosomes — 2-bit body +
 * run mask. Cross-language byte-exact with the Python
 * {@code ttio.genomic.packed_reference} module and the Objective-C
 * {@code TTIOPackedReference} class; the wire layout is documented in
 * the Python module docstring and format-spec §10.10.
 *
 * <p>Big-endian throughout. Version byte {@code 0x01}. Exception
 * bytes (anything but uppercase ACGT) are recorded as maximal runs
 * of {@code (uint32 position, uint32 length)} plus their original
 * bytes, so multi-megabase N runs cost 8 bytes + the run body rather
 * than a per-byte mask.</p>
 */
public final class PackedReference {

    public static final int VERSION = 0x01;
    public static final int HEADER_LEN = 9;
    public static final int RUN_ENTRY_LEN = 8;

    /** Below this ACGT fraction the packed layout loses to raw+zlib. */
    public static final double MIN_PACKABLE_FRACTION = 0.5;

    private static final byte[] CODE = buildCode();

    private static byte[] buildCode() {
        byte[] t = new byte[256];
        java.util.Arrays.fill(t, (byte) -1);
        t['A'] = 0; t['C'] = 1; t['G'] = 2; t['T'] = 3;
        return t;
    }

    private PackedReference() {}

    /** Fraction of bytes that are uppercase ACGT (1.0 for empty input). */
    public static double packableFraction(byte[] data) {
        if (data.length == 0) return 1.0;
        long acgt = 0;
        for (byte b : data) if (CODE[b & 0xFF] >= 0) acgt++;
        return (double) acgt / data.length;
    }

    /** Pack {@code data}; lossless for any byte content. */
    public static byte[] encode(byte[] data) {
        int n = data.length;
        List<int[]> runs = new ArrayList<>();
        int i = 0;
        long runTotal = 0;
        while (i < n) {
            if (CODE[data[i] & 0xFF] < 0) {
                int s = i;
                while (i < n && CODE[data[i] & 0xFF] < 0) i++;
                runs.add(new int[] { s, i - s });
                runTotal += i - s;
            } else {
                i++;
            }
        }
        long nAcgt = n - runTotal;
        int bodyLen = (int) ((nAcgt + 3) / 4);
        ByteBuffer out = ByteBuffer.allocate(
                HEADER_LEN + runs.size() * RUN_ENTRY_LEN + (int) runTotal + bodyLen);
        out.put((byte) VERSION).putInt(n).putInt(runs.size());
        for (int[] r : runs) out.putInt(r[0]).putInt(r[1]);
        for (int[] r : runs) out.put(data, r[0], r[1]);
        int acc = 0, slot = 0;
        int written = 0;
        byte[] body = new byte[bodyLen];
        for (int p = 0; p < n; p++) {
            int c = CODE[data[p] & 0xFF];
            if (c < 0) continue;
            acc = (acc << 2) | c;
            if (++slot == 4) {
                body[written++] = (byte) acc;
                acc = 0; slot = 0;
            }
        }
        if (slot != 0) body[written] = (byte) (acc << (2 * (4 - slot)));
        out.put(body);
        return out.array();
    }

    /**
     * Write one chromosome's bytes under {@code chromGroup} — as
     * {@code data_packed} when the packed layout is smaller, else as
     * the legacy raw {@code data} dataset. The pack decision (ACGT
     * fraction gate + exact size comparison) is deterministic on
     * content, so all three languages choose the same layout for the
     * same sequence. Keeps the Perf-A small-sequence contiguous path
     * and the no-compression provider fallback from the raw writer.
     */
    public static void writeChromosomeDataset(StorageGroup chromGroup, byte[] seq) {
        byte[] payload = seq;
        String name = "data";
        if (packableFraction(seq) >= MIN_PACKABLE_FRACTION) {
            byte[] candidate = encode(seq);
            if (candidate.length < seq.length) {
                payload = candidate;
                name = "data_packed";
            }
        }
        final int SMALL_SEQ_BYTES = 4096;
        StorageDataset ds;
        if (payload.length < SMALL_SEQ_BYTES) {
            ds = chromGroup.createDataset(name,
                Enums.Precision.UINT8, payload.length,
                0, Enums.Compression.NONE, 0);
        } else {
            try {
                ds = chromGroup.createDataset(name,
                    Enums.Precision.UINT8, payload.length,
                    Math.min(65536, payload.length),
                    Enums.Compression.ZLIB, 6);
            } catch (UnsupportedOperationException e) {
                ds = chromGroup.createDataset(name,
                    Enums.Precision.UINT8, payload.length,
                    0, Enums.Compression.NONE, 0);
            }
        }
        try (StorageDataset closeMe = ds) {
            closeMe.writeAll(payload);
        }
    }

    /**
     * Read one chromosome's bytes from {@code chromGroup}, decoding
     * the {@code data_packed} layout when present and falling back to
     * the legacy raw {@code data} dataset otherwise.
     */
    public static byte[] readChromosomeBytes(StorageGroup chromGroup) {
        if (chromGroup.hasChild("data_packed")) {
            try (StorageDataset ds = chromGroup.openDataset("data_packed")) {
                return decode((byte[]) ds.readAll());
            }
        }
        try (StorageDataset ds = chromGroup.openDataset("data")) {
            return (byte[]) ds.readAll();
        }
    }

    /** Inverse of {@link #encode}. */
    public static byte[] decode(byte[] stream) {
        if (stream.length < HEADER_LEN)
            throw new IllegalArgumentException("packed reference stream shorter than its header");
        ByteBuffer in = ByteBuffer.wrap(stream);
        int version = in.get() & 0xFF;
        if (version != VERSION)
            throw new IllegalArgumentException("unknown packed reference version " + version);
        int n = in.getInt();
        int runCount = in.getInt();
        int[][] runs = new int[runCount][2];
        long runTotal = 0;
        int prevEnd = -1;
        for (int r = 0; r < runCount; r++) {
            int pos = in.getInt(), len = in.getInt();
            if (len == 0 || pos <= prevEnd || (long) pos + len > n)
                throw new IllegalArgumentException("malformed exception run table");
            runs[r][0] = pos; runs[r][1] = len;
            prevEnd = pos + len - 1;
            runTotal += len;
        }
        byte[] out = new byte[n];
        boolean[] exc = new boolean[n];
        for (int[] r : runs) {
            in.get(out, r[0], r[1]);
            java.util.Arrays.fill(exc, r[0], r[0] + r[1], true);
        }
        long nAcgt = n - runTotal;
        byte[] lut = { 'A', 'C', 'G', 'T' };
        int consumed = 0;
        int body = 0;
        int slot = 4;
        for (int p = 0; p < n; p++) {
            if (exc[p]) continue;
            if (slot == 4) {
                body = in.get() & 0xFF;
                slot = 0;
            }
            out[p] = lut[(body >> (6 - 2 * slot)) & 0b11];
            slot++;
            consumed++;
        }
        if (consumed != nAcgt)
            throw new IllegalArgumentException("packed reference stream truncated in body");
        return out;
    }
}

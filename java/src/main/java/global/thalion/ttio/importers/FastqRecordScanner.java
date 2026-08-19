// SPDX-License-Identifier: Apache-2.0
package global.thalion.ttio.importers;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;

/**
 * Finds record boundaries inside a byte range of a plain (unwrapped,
 * uncompressed) FASTQ file, so the shard-mode producer can split a
 * file into ranges that each start on a record.
 *
 * <p>Boundary rule: a candidate is a {@code '@'} at offset 0 or one
 * preceded by {@code '\n'}. Because {@code '@'} (Phred 31) legally
 * appears anywhere in a quality string, a candidate confirms only when
 * the line two lines below it starts with {@code '+'}. The scanner
 * walks forward candidate by candidate inside a bounded window (1 MiB,
 * doubled up to 16 MiB when a record spans further).</p>
 *
 * <p>Cross-language equivalent: ObjC {@code TTIOFastqRecordScanner}.</p>
 */
public final class FastqRecordScanner {
    private FastqRecordScanner() { }

    private static final int WINDOW_INITIAL = 1 << 20;
    private static final int WINDOW_MAX = 16 << 20;

    /** The byte offset of the first record start at or after
     *  {@code offset}, or {@code fileLength} when no boundary confirms
     *  before the end of the file. */
    public static long boundaryAtOrAfter(FileChannel ch, long offset, long fileLength)
            throws IOException {
        if (offset >= fileLength) return fileLength;
        long base = offset > 0 ? offset - 1 : 0;
        int windowLen = WINDOW_INITIAL;
        while (base < fileLength) {
            ByteBuffer buf = ByteBuffer.allocate((int) Math.min(windowLen, fileLength - base));
            int n = ch.read(buf, base);
            if (n <= 0) return fileLength;
            byte[] b = buf.array();
            boolean grew = false;
            for (int i = 0; i < n; i++) {
                long abs = base + i;
                if (abs < offset) continue;
                boolean atStart = abs == 0 && b[i] == '@';
                boolean afterNl = i > 0 && b[i] == '@' && b[i - 1] == '\n';
                if (!atStart && !afterNl) continue;
                int confirm = confirmCandidate(b, i, n);
                if (confirm > 0) return abs;
                if (confirm < 0) {
                    if (base + n >= fileLength) return fileLength;
                    if (windowLen < WINDOW_MAX) {
                        windowLen *= 2;
                        grew = true;
                        break;
                    }
                    // Pathological line beyond the cap: skip candidate.
                }
            }
            if (grew) continue;
            if (base + n >= fileLength) return fileLength;
            base += n - 1;   // overlap by 1 so an edge "\n@" is seen
        }
        return fileLength;
    }

    /** 1 = confirmed, 0 = rejected, -1 = window too short (grow). */
    static int confirmCandidate(byte[] b, int index, int len) {
        if (index >= len || b[index] != '@') return 0;
        int i = index;
        while (i < len && b[i] != '\n') i++;
        if (i >= len) return -1;
        int j = i + 1;
        while (j < len && b[j] != '\n') j++;
        if (j >= len) return -1;
        int k = j + 1;
        if (k >= len) return -1;
        return b[k] == '+' ? 1 : 0;
    }
}

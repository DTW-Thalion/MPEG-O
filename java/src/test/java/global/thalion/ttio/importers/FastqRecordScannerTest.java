// SPDX-License-Identifier: Apache-2.0
package global.thalion.ttio.importers;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class FastqRecordScannerTest {

    private static byte[] record(String name, String seq, String qual) {
        return ("@" + name + "\n" + seq + "\n+\n" + qual + "\n").getBytes(StandardCharsets.ISO_8859_1);
    }

    @Test
    void boundaries(@TempDir Path tmp) throws Exception {
        // Record 1's quality string STARTS with '@': the false candidate.
        byte[] r1 = record("r1", "ACGTACGT", "@IIIIIII");
        byte[] r2 = record("r2", "TTTTGGGG", "IIIIIIII");
        byte[] r3 = record("r3", "CCCCAAAA", "IIIIIIII");
        Path p = tmp.resolve("frs.fastq");
        try (var out = Files.newOutputStream(p)) {
            out.write(r1); out.write(r2); out.write(r3);
        }
        long len = Files.size(p);
        long r2at = r1.length, r3at = r1.length + r2.length;
        try (FileChannel ch = FileChannel.open(p, StandardOpenOption.READ)) {
            assertEquals(0, FastqRecordScanner.boundaryAtOrAfter(ch, 0, len));
            assertEquals(r2at, FastqRecordScanner.boundaryAtOrAfter(ch, 1, len),
                "'@' in a quality line must be rejected");
            assertEquals(r3at, FastqRecordScanner.boundaryAtOrAfter(ch, r2at + 3, len));
            assertEquals(len, FastqRecordScanner.boundaryAtOrAfter(ch, r3at + 1, len));
        }
        // Truncated final record: still no boundary, never a hang.
        Path p2 = tmp.resolve("frs2.fastq");
        byte[] whole = Files.readAllBytes(p);
        try (var out = Files.newOutputStream(p2)) {
            out.write(whole, 0, whole.length - 5);
        }
        try (FileChannel ch = FileChannel.open(p2, StandardOpenOption.READ)) {
            long l2 = Files.size(p2);
            assertEquals(l2, FastqRecordScanner.boundaryAtOrAfter(ch, r3at + 1, l2));
        }
        // The exposed validator: growth requested when the window ends
        // before the '+' line.
        assertTrue(FastqRecordScanner.confirmCandidate(r2, 0, 6) < 0);
    }
}

/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.genomics.ReferenceImport;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Defensive parsing of FASTA files containing literal {@code "\n"}
 * byte pairs ({@code 0x5C 0x6E}) inside record lines instead of real
 * line breaks. Some buggy TSV-to-FASTA converters produce this shape;
 * without the unescape every record parses as an empty-sequence
 * header and downstream encoding wastes O(N) HDF5 overhead on
 * nothing.
 */
class FastaReaderMalformedTest {

    @Test
    void literalBackslashNBetweenHeaderAndBodyIsTreatedAsNewline(
            @TempDir Path tmp) throws Exception {
        Path fa = tmp.resolve("malformed.fa");
        // Two records, each one line with literal \n (0x5C 0x6E) between
        // header and sequence and a real LF terminating the record.
        byte[] data = new byte[] {
            '>','c','h','r','1', 0x5C, 0x6E, 'A','C','G','T','A','C','G','T', 0x0A,
            '>','c','h','r','2', 0x5C, 0x6E, 'T','T','T','T','C','C','C','C', 0x0A,
        };
        Files.write(fa, data);

        ReferenceImport ref = new FastaReader(fa).readReference("ref://test");
        assertEquals(2, ref.chromosomes().size(),
            "two records expected");
        assertEquals("chr1", ref.chromosomes().get(0));
        assertEquals("chr2", ref.chromosomes().get(1));
        assertArrayEquals("ACGTACGT".getBytes(), ref.sequences().get(0));
        assertArrayEquals("TTTTCCCC".getBytes(), ref.sequences().get(1));
    }

    @Test
    void normalFastaWithRealNewlinesIsUnchanged(@TempDir Path tmp) throws Exception {
        Path fa = tmp.resolve("normal.fa");
        String content = ">chr1\nACGTACGT\n>chr2\nTTTTCCCC\n";
        Files.writeString(fa, content);

        ReferenceImport ref = new FastaReader(fa).readReference("ref://test");
        assertEquals(2, ref.chromosomes().size());
        assertArrayEquals("ACGTACGT".getBytes(), ref.sequences().get(0));
        assertArrayEquals("TTTTCCCC".getBytes(), ref.sequences().get(1));
    }

    @Test
    void loneBackslashNotFollowedByNIsPreserved(@TempDir Path tmp) throws Exception {
        // A backslash followed by anything other than 'n' must NOT be
        // interpreted as a newline — emit the backslash and the next
        // byte verbatim. (Headers and sequences in real FASTA shouldn't
        // contain backslashes, but the parser shouldn't corrupt them.)
        Path fa = tmp.resolve("loneBackslash.fa");
        // ">chr1\nACGT\\xACGT\n" — backslash + 'x' (0x78) in body
        byte[] data = new byte[] {
            '>','c','h','r','1', 0x0A,
            'A','C','G','T', 0x5C, 'x', 'A','C','G','T', 0x0A,
        };
        Files.write(fa, data);
        ReferenceImport ref = new FastaReader(fa).readReference("ref://test");
        assertEquals(1, ref.chromosomes().size());
        byte[] seq = ref.sequences().get(0);
        assertArrayEquals(new byte[] {
            'A','C','G','T', 0x5C, 'x', 'A','C','G','T'
        }, seq);
    }

    @Test
    void backslashAtEndOfFileIsPreserved(@TempDir Path tmp) throws Exception {
        Path fa = tmp.resolve("trailingBackslash.fa");
        // ">chr1\nACGT\\" — trailing backslash, no newline after
        byte[] data = new byte[] {
            '>','c','h','r','1', 0x0A,
            'A','C','G','T', 0x5C,
        };
        Files.write(fa, data);
        ReferenceImport ref = new FastaReader(fa).readReference("ref://test");
        assertEquals(1, ref.chromosomes().size());
        byte[] seq = ref.sequences().get(0);
        // Trailing backslash should be preserved.
        assertArrayEquals(new byte[] { 'A','C','G','T', 0x5C }, seq);
    }
}

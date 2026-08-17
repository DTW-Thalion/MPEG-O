/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import global.thalion.ttio.importers.FastaReader;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/** {@link LazyReference} over the m88 test reference. */
class LazyReferenceTest {

    private static final Path FASTA = Paths.get("src", "test", "resources", "ttio",
            "fixtures", "genomic", "m88_test_reference.fa");

    @Test
    void chromosomesMatchTheWholeFileLoader() throws Exception {
        ReferenceImport whole = new FastaReader(FASTA).readReference("m88");
        LazyReference lazy = new LazyReference(FASTA);
        assertEquals(new ArrayList<>(whole.chromosomes()), new ArrayList<>(lazy.keySet()));
        for (String c : whole.chromosomes()) {
            assertTrue(lazy.containsKey(c));
            assertEquals(whole.chromosome(c).length, lazy.lengthOf(c));
            assertArrayEquals(whole.chromosome(c), lazy.get(c));
        }
        assertNull(lazy.get("nope"));
        assertFalse(lazy.containsKey("nope"));
        assertEquals(whole.chromosomes().size(), lazy.size());
        // entrySet iteration loads values one at a time
        List<String> seen = new ArrayList<>();
        for (Map.Entry<String, byte[]> e : lazy.entrySet()) {
            seen.add(e.getKey());
            assertEquals(lazy.lengthOf(e.getKey()), e.getValue().length);
        }
        assertEquals(new ArrayList<>(whole.chromosomes()), seen);
        // the same MD5 the whole-file loader computes
        List<byte[]> seqs = new ArrayList<>();
        List<String> names = new ArrayList<>(whole.chromosomes());
        java.util.Collections.sort(names);
        for (String n : names) seqs.add(lazy.get(n));
        assertArrayEquals(ReferenceImport.computeMd5(names, seqs), whole.md5());
        assertTrue(Files.exists(Path.of(FASTA + ".fai")));
    }
}

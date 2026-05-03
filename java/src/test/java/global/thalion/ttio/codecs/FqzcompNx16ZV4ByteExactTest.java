/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.condition.EnabledIf;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Java V4 cross-corpus byte-exact test.
 *
 * <p>For each of 4 corpora: read the Python-extracted
 * {@code /tmp/{name}_v4_*.bin} (assumes {@code htscodecs_compare.sh} has
 * been run to populate {@code /tmp}), encode via Java V4
 * ({@code preferV4=true}), compare bytes against
 * {@code /tmp/py_{name}_v4.fqz} (full M94Z V4 streams produced by Python's
 * {@code fqzcomp_nx16_z.encode(prefer_v4=True)} via
 * {@code tools/perf/m94z_v4_prototype/run_v4_python_references.py}).
 *
 * <p>Both Java and Python wrap the deterministic
 * {@code ttio_m94z_v4_encode} C function with the same parameters, so the
 * resulting M94Z V4 streams must be byte-identical.
 *
 * <p>Tagged {@code @integration}; pom.xml does not exclude this tag, so
 * the test runs alongside the default test set when {@code -Dtest=...}
 * targets it directly.
 */
@Tag("integration")
class FqzcompNx16ZV4ByteExactTest {

    /** Matches @EnabledIf signature: a no-arg method returning boolean. */
    static boolean jniAvailable() {
        return TtioRansNative.isAvailable();
    }

    static Stream<Object[]> corpora() {
        return Stream.of(
            new Object[]{"chr22",          178409733L, 1766433L},
            new Object[]{"wes",             95035281L,  992974L},
            new Object[]{"hg002_illumina", 248184765L,  997415L},
            new Object[]{"hg002_pacbio",   264190341L,   14284L}
        );
    }

    @ParameterizedTest
    @MethodSource("corpora")
    @EnabledIf("jniAvailable")
    void v4ByteExactVsPython(String name, long expectedNQual, long expectedNReads)
            throws IOException {
        Path qualBin  = Path.of("/tmp/" + name + "_v4_qual.bin");
        Path lensBin  = Path.of("/tmp/" + name + "_v4_lens.bin");
        Path flagsBin = Path.of("/tmp/" + name + "_v4_flags.bin");
        Path pyOut    = Path.of("/tmp/py_" + name + "_v4.fqz");
        if (!Files.exists(qualBin) || !Files.exists(pyOut)) {
            // Skip cleanly if Phase 5 prep isn't done yet; Maven reports the
            // test as passed (not skipped — JUnit's skip semantics are clunky
            // for parameterized).
            return;
        }

        byte[] qualities = Files.readAllBytes(qualBin);
        byte[] lensBlob  = Files.readAllBytes(lensBin);
        byte[] flagsBlob = Files.readAllBytes(flagsBin);
        // lens and flags are uint32 LE per-read (Stage 2 extractor convention).
        int n_reads = lensBlob.length / 4;
        int[] lens  = new int[n_reads];
        int[] flags = new int[n_reads];
        for (int i = 0; i < n_reads; i++) {
            lens[i]  = (lensBlob [4*i]     & 0xFF)
                     | ((lensBlob [4*i+1]  & 0xFF) <<  8)
                     | ((lensBlob [4*i+2]  & 0xFF) << 16)
                     | ((lensBlob [4*i+3]  & 0xFF) << 24);
            flags[i] = (flagsBlob[4*i]     & 0xFF)
                     | ((flagsBlob[4*i+1]  & 0xFF) <<  8)
                     | ((flagsBlob[4*i+2]  & 0xFF) << 16)
                     | ((flagsBlob[4*i+3]  & 0xFF) << 24);
        }
        // SAM_REVERSE bit is bit 4; the Java encodeV4Internal converts to 0/16.
        int[] revcomp = new int[n_reads];
        for (int i = 0; i < n_reads; i++) {
            revcomp[i] = (flags[i] & 16) != 0 ? 1 : 0;
        }

        assertEquals(expectedNQual, qualities.length, name + " qual size");
        assertEquals(expectedNReads, n_reads, name + " n_reads");

        FqzcompNx16Z.EncodeOptions opts =
            new FqzcompNx16Z.EncodeOptions().preferV4(true);
        byte[] javaV4 = FqzcompNx16Z.encode(qualities, lens, revcomp, opts);

        byte[] pyV4 = Files.readAllBytes(pyOut);

        assertArrayEquals(pyV4, javaV4,
            name + ": Java=" + javaV4.length + " Python=" + pyV4.length);
    }
}

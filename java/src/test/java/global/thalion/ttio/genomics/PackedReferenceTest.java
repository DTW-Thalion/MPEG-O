/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.genomics;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Packed reference storage — codec round-trip and the pack decision.
 * Cross-language byte-exact with Python's
 * {@code ttio.genomic.packed_reference}: the golden-stream test below
 * pins the same bytes as
 * {@code tests/test_packed_reference.py::test_golden_stream_bytes}.
 */
class PackedReferenceTest {

    static Map<String, byte[]> cases() {
        Map<String, byte[]> m = new LinkedHashMap<>();
        m.put("empty", new byte[0]);
        m.put("pure_acgt", b("ACGTACGTACGT"));
        m.put("all_n", b("N".repeat(1000)));
        m.put("n_runs_both_ends", b("N".repeat(507) + "ACGT".repeat(250) + "N".repeat(33)));
        m.put("iupac_mixed", b("ACGTRYSWKMBDHVNacgt".repeat(97)));
        m.put("single_base", b("G"));
        m.put("single_exception", b("n"));
        m.put("trailing_partial_byte", b("ACGTA"));
        m.put("alternating_exceptions", b("ANANANANAN".repeat(55)));
        return m;
    }

    private static byte[] b(String s) {
        return s.getBytes(StandardCharsets.US_ASCII);
    }

    static java.util.stream.Stream<String> caseNames() {
        return cases().keySet().stream();
    }

    @ParameterizedTest
    @MethodSource("caseNames")
    void roundTrip(String name) {
        byte[] data = cases().get(name);
        assertArrayEquals(data, PackedReference.decode(PackedReference.encode(data)), name);
    }

    @Test
    void nRunsCostRunEntriesNotBytes() {
        byte[] data = b("N".repeat(1_000_000) + "ACGT".repeat(1000));
        byte[] enc = PackedReference.encode(data);
        assertTrue(enc.length < data.length + 100,
            "a megabase N run must cost one 8-byte run entry, not a per-byte mask");
    }

    @Test
    void versionGateRejectsUnknown() {
        byte[] enc = PackedReference.encode(b("ACGT"));
        enc[0] = 0x7F;
        assertThrows(IllegalArgumentException.class, () -> PackedReference.decode(enc));
    }

    @Test
    void goldenStreamBytes() {
        // Byte-exact pin shared with Python's
        // test_packed_reference.py::test_golden_stream_bytes.
        byte[] data = b("N".repeat(7) + "ACGTACGTGG" + "n" + "TTT");
        byte[] golden = hex(
            "010000001500000002000000000000000700000011000000"
            + "014e4e4e4e4e4e4e6e1b1bafc0");
        assertArrayEquals(golden, PackedReference.encode(data));
        assertArrayEquals(data, PackedReference.decode(golden));
    }

    private static byte[] hex(String s) {
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        }
        return out;
    }

    @Test
    void packableFraction() {
        assertEquals(1.0, PackedReference.packableFraction(new byte[0]));
        assertEquals(1.0, PackedReference.packableFraction(b("ACGT")));
        assertEquals(0.0, PackedReference.packableFraction(b("acgt")));
        assertEquals(0.5, PackedReference.packableFraction(b("AANN")));
    }
}

/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.Identification;
import global.thalion.ttio.Quantification;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Round-trip coverage for {@link ArrowIpcCodec}. The codec is used to
 * serialize tabular packet payloads for transport-spec v0.11 packet
 * types IDENTIFICATIONS_TABLE (0x16) and QUANTIFICATIONS_TABLE (0x17).
 */
class ArrowIpcCodecTest {

    @Test
    void identifications_round_trip_through_arrow_ipc() {
        Identification id1 = new Identification(
            "run_A", 42, "CHEBI:16236", 0.91,
            List.of("PSI-MS:1001143", "PSI-MS:1001172"));
        Identification id2 = new Identification(
            "run_B", 17, "C6H12O6", 0.77,
            List.of("PSI-MS:1002012"));

        byte[] ipc = ArrowIpcCodec.encodeIdentifications(List.of(id1, id2));
        assertTrue(ipc.length > 0, "Arrow IPC stream non-empty");

        List<Identification> out = ArrowIpcCodec.decodeIdentifications(ipc);
        assertEquals(2, out.size());

        assertEquals(id1.runName(),         out.get(0).runName());
        assertEquals(id1.spectrumIndex(),   out.get(0).spectrumIndex());
        assertEquals(id1.chemicalEntity(),  out.get(0).chemicalEntity());
        assertEquals(id1.confidenceScore(), out.get(0).confidenceScore(), 1e-12);
        assertEquals(id1.evidenceChain(),   out.get(0).evidenceChain());

        assertEquals(id2.runName(),         out.get(1).runName());
        assertEquals(id2.spectrumIndex(),   out.get(1).spectrumIndex());
        assertEquals(id2.chemicalEntity(),  out.get(1).chemicalEntity());
        assertEquals(id2.confidenceScore(), out.get(1).confidenceScore(), 1e-12);
        assertEquals(id2.evidenceChain(),   out.get(1).evidenceChain());
    }

    @Test
    void empty_identifications_round_trip() {
        byte[] ipc = ArrowIpcCodec.encodeIdentifications(List.of());
        assertTrue(ipc.length > 0, "even empty payload yields a valid IPC stream");
        List<Identification> out = ArrowIpcCodec.decodeIdentifications(ipc);
        assertTrue(out.isEmpty());
    }

    @Test
    void identifications_with_empty_evidence_chain_round_trip() {
        Identification id = new Identification(
            "run_C", 0, "CHEBI:00000", 0.5, List.of());
        byte[] ipc = ArrowIpcCodec.encodeIdentifications(List.of(id));
        List<Identification> out = ArrowIpcCodec.decodeIdentifications(ipc);
        assertEquals(1, out.size());
        assertEquals(List.of(), out.get(0).evidenceChain());
    }

    @Test
    void quantifications_round_trip() {
        Quantification q1 = new Quantification(
            "CHEBI:16236", "sample_X", 12.5, "TIC", "peak-area");
        Quantification q2 = new Quantification(
            "C6H12O6", "sample_Y", 0.0033, "median", "ng/mL");

        byte[] ipc = ArrowIpcCodec.encodeQuantifications(List.of(q1, q2));
        List<Quantification> out = ArrowIpcCodec.decodeQuantifications(ipc);
        assertEquals(2, out.size());

        assertEquals(q1.chemicalEntity(),      out.get(0).chemicalEntity());
        assertEquals(q1.sampleRef(),           out.get(0).sampleRef());
        assertEquals(q1.abundance(),           out.get(0).abundance(), 1e-12);
        assertEquals(q1.normalizationMethod(), out.get(0).normalizationMethod());
        assertEquals(q1.unit(),                out.get(0).unit());

        assertEquals(q2.chemicalEntity(),      out.get(1).chemicalEntity());
        assertEquals(q2.sampleRef(),           out.get(1).sampleRef());
        assertEquals(q2.abundance(),           out.get(1).abundance(), 1e-12);
        assertEquals(q2.normalizationMethod(), out.get(1).normalizationMethod());
        assertEquals(q2.unit(),                out.get(1).unit());
    }

    @Test
    void empty_quantifications_round_trip() {
        byte[] ipc = ArrowIpcCodec.encodeQuantifications(List.of());
        assertTrue(ipc.length > 0, "even empty payload yields a valid IPC stream");
        assertTrue(ArrowIpcCodec.decodeQuantifications(ipc).isEmpty());
    }

    @Test
    void quantifications_with_empty_unit_round_trip() {
        // The 4-arg ctor defaults unit to "".
        Quantification q = new Quantification("CHEBI:1", "s", 1.0, "raw");
        byte[] ipc = ArrowIpcCodec.encodeQuantifications(List.of(q));
        List<Quantification> out = ArrowIpcCodec.decodeQuantifications(ipc);
        assertEquals(1, out.size());
        assertEquals("", out.get(0).unit());
    }
}

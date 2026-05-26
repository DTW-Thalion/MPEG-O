/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.Sample;
import global.thalion.ttio.Subject;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Stage 6 (transport-spec v0.11): exercise the
 * {@link ArrowIpcCodec#encodeSubjects} / {@code decodeSubjects} and
 * {@link ArrowIpcCodec#encodeSamples} / {@code decodeSamples} round-
 * trips at the codec layer (no transport framing). Mirrors the shape of
 * {@link ArrowIpcCodecTest} for identifications / quantifications.
 *
 * <p>Spec references:</p>
 * <ul>
 *   <li>{@code docs/superpowers/specs/2026-05-26-subjects-samples-design.md} §6 — wire schemas</li>
 *   <li>spec §11 — null handling: optional strings ↔ Arrow null,
 *       sentinel 0 ↔ Arrow null for {@code birth_year} +
 *       {@code collected_at}, {@code attributes_json} always present.</li>
 * </ul>
 */
class ArrowIpcCodecSubjectsSamplesTest {

    // ------------------------------------------------------------------
    // Subjects
    // ------------------------------------------------------------------

    @Test
    void empty_subjects_round_trip() {
        byte[] ipc = ArrowIpcCodec.encodeSubjects(List.of());
        // Even the empty case ships the schema header, so the byte
        // payload is non-empty by design — that's the value of using
        // Arrow IPC framing here.
        assertNotNull(ipc);
        assertTrue(ipc.length > 0,
            "empty subjects must still ship a schema-only IPC stream");
        List<Subject> back = ArrowIpcCodec.decodeSubjects(ipc);
        assertTrue(back.isEmpty(),
            "empty subjects round trip must yield an empty list");
    }

    @Test
    void subjects_with_all_fields_round_trip() {
        Map<String, String> attrs = new LinkedHashMap<>();
        attrs.put("notes", "fully populated subject");
        attrs.put("cohort", "control");
        Subject a = new Subject("SUB-001", "PROJ_A", "F", 1985L, attrs);
        Subject b = new Subject("SUB-002", "PROJ_B", "M", 1970L,
            Map.of("notes", "second"));
        byte[] ipc = ArrowIpcCodec.encodeSubjects(List.of(a, b));
        List<Subject> back = ArrowIpcCodec.decodeSubjects(ipc);
        assertEquals(2, back.size());
        Subject ba = back.get(0);
        assertEquals("SUB-001", ba.externalId());
        assertEquals("PROJ_A",  ba.project());
        assertEquals("F",       ba.sex());
        assertEquals(1985L,     ba.birthYear());
        assertEquals(attrs,     ba.attributes());
        Subject bb = back.get(1);
        assertEquals("SUB-002", bb.externalId());
        assertEquals("PROJ_B",  bb.project());
        assertEquals("M",       bb.sex());
        assertEquals(1970L,     bb.birthYear());
        assertEquals(Map.of("notes", "second"), bb.attributes());
    }

    /** Optional string fields and the {@code birth_year} integer
     *  encode as Arrow null when the source is the unset sentinel
     *  ({@code ""} / {@code 0}); the read side decodes them back to
     *  the same sentinel. */
    @Test
    void subjects_with_optional_nulls_round_trip() {
        // unset project, sex, birthYear and no attributes
        Subject s = new Subject("SUB-ANON", "", "", 0L, Map.of());
        byte[] ipc = ArrowIpcCodec.encodeSubjects(List.of(s));
        List<Subject> back = ArrowIpcCodec.decodeSubjects(ipc);
        assertEquals(1, back.size());
        Subject r = back.get(0);
        assertEquals("SUB-ANON", r.externalId());
        assertEquals("",         r.project(),
            "empty project must round-trip as empty string via Arrow null");
        assertEquals("",         r.sex(),
            "empty sex must round-trip as empty string via Arrow null");
        assertEquals(0L,         r.birthYear(),
            "sentinel-0 birth_year must round-trip as 0 via Arrow null");
        assertEquals(Map.of(),   r.attributes(),
            "empty attributes_json (\"{}\") must round-trip as empty map");
    }

    @Test
    void subjects_attributes_with_special_chars_round_trip() {
        Map<String, String> attrs = new LinkedHashMap<>();
        attrs.put("description", "needs \"escaping\" + Unicode: é");
        attrs.put("path", "/tmp/data");
        attrs.put("k3", "");
        Subject s = new Subject("SUB-SPECIAL", "P", "NA", 2000L, attrs);
        byte[] ipc = ArrowIpcCodec.encodeSubjects(List.of(s));
        List<Subject> back = ArrowIpcCodec.decodeSubjects(ipc);
        assertEquals(1, back.size());
        // Subject.attributesJson uses sort_keys=true on write but the
        // post-decode map round-trips logically, not by insertion
        // order (key set + values must match).
        assertEquals(attrs.keySet(), back.get(0).attributes().keySet());
        for (var e : attrs.entrySet()) {
            assertEquals(e.getValue(), back.get(0).attributes().get(e.getKey()));
        }
    }

    // ------------------------------------------------------------------
    // Samples
    // ------------------------------------------------------------------

    @Test
    void empty_samples_round_trip() {
        byte[] ipc = ArrowIpcCodec.encodeSamples(List.of());
        assertNotNull(ipc);
        assertTrue(ipc.length > 0);
        List<Sample> back = ArrowIpcCodec.decodeSamples(ipc);
        assertTrue(back.isEmpty());
    }

    @Test
    void samples_with_all_fields_round_trip() {
        Map<String, String> attrs = new LinkedHashMap<>();
        attrs.put("tissue", "liver");
        attrs.put("notes", "freshly collected");
        Sample a = new Sample("SAMP-001", "SUB-001", "tissue",
            1700000000L, attrs);
        Sample b = new Sample("SAMP-002", "SUB-002", "plasma",
            1700001000L, Map.of("notes", "second"));
        byte[] ipc = ArrowIpcCodec.encodeSamples(List.of(a, b));
        List<Sample> back = ArrowIpcCodec.decodeSamples(ipc);
        assertEquals(2, back.size());
        Sample ba = back.get(0);
        assertEquals("SAMP-001",   ba.sampleId());
        assertEquals("SUB-001",    ba.subjectExternalId());
        assertEquals("tissue",     ba.sampleKind());
        assertEquals(1700000000L,  ba.collectedAt());
        assertEquals(attrs,        ba.attributes());
        Sample bb = back.get(1);
        assertEquals("SAMP-002",   bb.sampleId());
        assertEquals("SUB-002",    bb.subjectExternalId());
        assertEquals("plasma",     bb.sampleKind());
        assertEquals(1700001000L,  bb.collectedAt());
    }

    @Test
    void samples_with_optional_nulls_round_trip() {
        Sample s = new Sample("SAMP-ANON", "", "", 0L, Map.of());
        byte[] ipc = ArrowIpcCodec.encodeSamples(List.of(s));
        List<Sample> back = ArrowIpcCodec.decodeSamples(ipc);
        assertEquals(1, back.size());
        Sample r = back.get(0);
        assertEquals("SAMP-ANON", r.sampleId());
        assertEquals("",          r.subjectExternalId());
        assertEquals("",          r.sampleKind());
        assertEquals(0L,          r.collectedAt());
        assertEquals(Map.of(),    r.attributes());
    }

    @Test
    void samples_attributes_with_special_chars_round_trip() {
        Map<String, String> attrs = new LinkedHashMap<>();
        attrs.put("description", "split on \"comma,inside\"");
        attrs.put("path", "/var/log");
        Sample s = new Sample("SAMP-SPECIAL", "SUB-X", "plasma",
            1700000000L, attrs);
        byte[] ipc = ArrowIpcCodec.encodeSamples(List.of(s));
        List<Sample> back = ArrowIpcCodec.decodeSamples(ipc);
        assertEquals(1, back.size());
        assertEquals(attrs.keySet(), back.get(0).attributes().keySet());
        for (var e : attrs.entrySet()) {
            assertEquals(e.getValue(), back.get(0).attributes().get(e.getKey()));
        }
    }
}

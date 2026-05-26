/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.logging.Handler;
import java.util.logging.Level;
import java.util.logging.LogRecord;
import java.util.logging.Logger;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Stage 6 (transport-spec v0.11, Deferral 2): verify that
 * {@link SpectralDataset} persists {@link Subject} + {@link Sample}
 * lists as per-row HDF5 groups under {@code /study/subjects/} and
 * {@code /study/samples/}, and rehydrates them via the
 * {@link SpectralDataset#subjects()} / {@link SpectralDataset#samples()}
 * accessors. Backs design spec
 * {@code 2026-05-26-subjects-samples-design.md} §4 + §5.
 */
class SpectralDatasetSubjectsSamplesTest {

    @TempDir
    Path tempDir;

    // ── Round-trip ──────────────────────────────────────────────────

    /** Empty Subject + Sample lists round-trip as empty lists with no
     *  on-disk {@code /study/subjects/} or {@code /study/samples/}
     *  groups (spec §5 empty-case rule). The 7-arg create overload
     *  exercises the back-compat path that defaults both to empty. */
    @Test
    void emptyRoundTrip() {
        String path = tempDir.resolve("empty.tio").toString();

        try (SpectralDataset ds = SpectralDataset.create(path, "Empty",
                "ISA-EMPTY", List.of(), List.of(), List.of(), List.of())) {
            assertNotNull(ds);
            assertTrue(ds.subjects().isEmpty(), "subjects() must be empty at create()");
            assertTrue(ds.samples().isEmpty(), "samples() must be empty at create()");
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            assertTrue(ds.subjects().isEmpty(),
                "subjects() must be empty after reopen of an empty dataset");
            assertTrue(ds.samples().isEmpty(),
                "samples() must be empty after reopen of an empty dataset");
        }
    }

    /** Non-empty round-trip: 2 Subjects + 3 Samples; all fields
     *  preserved after close + reopen, including the open
     *  {@code attributes} Map. */
    @Test
    void nonEmptyRoundTrip() {
        String path = tempDir.resolve("populated.tio").toString();

        Subject s1 = new Subject("SUBJ-001", "ThalionCohortA", "F", 1985,
            Map.of("ethnicity", "ASN", "consent", "v2"));
        Subject s2 = new Subject("SUBJ-002", "ThalionCohortA", "M", 1978, Map.of());

        Sample sample1 = new Sample("SAMPLE-001", "SUBJ-001", "plasma",
            1_700_000_000L, Map.of("aliquot", "A"));
        Sample sample2 = new Sample("SAMPLE-002", "SUBJ-002", "tissue", 0L,
            Map.of("preservation", "FFPE"));
        Sample sample3 = new Sample("SAMPLE-ANON", "", "swab", 1_700_001_000L,
            Map.of());

        try (SpectralDataset ds = SpectralDataset.create(path, "Populated",
                "ISA-POP", List.of(), List.of(), List.of(), List.of(),
                List.of(s1, s2), List.of(sample1, sample2, sample3))) {
            assertNotNull(ds);
            assertEquals(2, ds.subjects().size());
            assertEquals(3, ds.samples().size());
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            List<Subject> subjects = ds.subjects();
            assertEquals(2, subjects.size(),
                "two Subjects must round-trip from /study/subjects/");
            // Iteration order matches on-disk childNames; not guaranteed
            // to be the input order in HDF5, so look up by ID.
            Subject r1 = findSubject(subjects, "SUBJ-001");
            assertNotNull(r1);
            assertEquals("ThalionCohortA", r1.project());
            assertEquals("F", r1.sex());
            assertEquals(1985L, r1.birthYear());
            assertEquals("ASN", r1.attributes().get("ethnicity"));
            assertEquals("v2", r1.attributes().get("consent"));

            Subject r2 = findSubject(subjects, "SUBJ-002");
            assertNotNull(r2);
            assertEquals("M", r2.sex());
            assertEquals(1978L, r2.birthYear());
            assertTrue(r2.attributes().isEmpty());

            List<Sample> samples = ds.samples();
            assertEquals(3, samples.size(),
                "three Samples must round-trip from /study/samples/");
            Sample rs1 = findSample(samples, "SAMPLE-001");
            assertNotNull(rs1);
            assertEquals("SUBJ-001", rs1.subjectExternalId());
            assertEquals("plasma", rs1.sampleKind());
            assertEquals(1_700_000_000L, rs1.collectedAt());
            assertEquals("A", rs1.attributes().get("aliquot"));

            Sample rs2 = findSample(samples, "SAMPLE-002");
            assertNotNull(rs2);
            assertEquals(0L, rs2.collectedAt(),
                "sentinel 0 (unknown) must round-trip on collectedAt");
            assertEquals("FFPE", rs2.attributes().get("preservation"));

            Sample rs3 = findSample(samples, "SAMPLE-ANON");
            assertNotNull(rs3);
            assertEquals("", rs3.subjectExternalId(),
                "anonymous sample subjectExternalId must remain empty");
            assertEquals("swab", rs3.sampleKind());
        }
    }

    // ── Validation: duplicate IDs raise ─────────────────────────────

    @Test
    void duplicateSubjectIdRaises() {
        String path = tempDir.resolve("dup_subj.tio").toString();
        Subject a = new Subject("SUBJ-001", "p", "F", 1990, Map.of());
        Subject b = new Subject("SUBJ-001", "p", "M", 1991, Map.of());
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
            () -> SpectralDataset.create(path, "dup", "ISA",
                List.of(), List.of(), List.of(), List.of(),
                List.of(a, b), List.of()));
        assertTrue(ex.getMessage().contains("duplicate Subject.externalId"),
            "error must name the duplicate-Subject rule; got: " + ex.getMessage());
        assertTrue(ex.getMessage().contains("SUBJ-001"),
            "error must include the duplicate id; got: " + ex.getMessage());
    }

    @Test
    void duplicateSampleIdRaises() {
        String path = tempDir.resolve("dup_samp.tio").toString();
        Sample a = new Sample("SAMP-1", "", "kind", 0, Map.of());
        Sample b = new Sample("SAMP-1", "", "kind", 0, Map.of());
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
            () -> SpectralDataset.create(path, "dup", "ISA",
                List.of(), List.of(), List.of(), List.of(),
                List.of(), List.of(a, b)));
        assertTrue(ex.getMessage().contains("duplicate Sample.sampleId"),
            "error must name the duplicate-Sample rule; got: " + ex.getMessage());
    }

    // ── Validation: empty / slash IDs raise (record-level) ──────────

    @Test
    void emptySubjectIdRaisesAtRecordConstruction() {
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
            () -> new Subject("", "p", "F", 2000, Map.of()));
        assertTrue(ex.getMessage().contains("must be non-empty"));
    }

    @Test
    void emptySampleIdRaisesAtRecordConstruction() {
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
            () -> new Sample("", "subj", "k", 0, Map.of()));
        assertTrue(ex.getMessage().contains("must be non-empty"));
    }

    @Test
    void subjectIdWithSlashRaises() {
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
            () -> new Subject("bad/id", "p", "F", 2000, Map.of()));
        assertTrue(ex.getMessage().contains("may not contain '/'"));
    }

    @Test
    void sampleIdWithSlashRaises() {
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
            () -> new Sample("bad/id", "s", "k", 0, Map.of()));
        assertTrue(ex.getMessage().contains("may not contain '/'"));
    }

    // ── Soft-FK mismatch: WARNING, not error ────────────────────────

    /** A Sample whose subjectExternalId does not match any Subject in
     *  the same dataset must still be persisted, but the writer logs a
     *  WARNING. Spec §4.4: soft-FK semantics. */
    @Test
    void softFkMismatchLogsWarningButDoesNotFail() {
        String path = tempDir.resolve("soft_fk.tio").toString();

        Subject knownSubj = new Subject("SUBJ-KNOWN", "p", "F", 1990, Map.of());
        Sample danglingSample = new Sample("SAMP-DANGLING", "SUBJ-MISSING",
            "tissue", 0, Map.of());

        // Attach a Handler to the SpectralDataset logger to capture
        // WARNING records emitted during create().
        Logger log = Logger.getLogger(SpectralDataset.class.getName());
        Level oldLevel = log.getLevel();
        boolean oldUseParent = log.getUseParentHandlers();
        java.util.List<LogRecord> captured = new java.util.ArrayList<>();
        Handler capture = new Handler() {
            @Override public void publish(LogRecord r) { captured.add(r); }
            @Override public void flush() {}
            @Override public void close() throws SecurityException {}
        };
        capture.setLevel(Level.ALL);
        log.addHandler(capture);
        log.setLevel(Level.ALL);
        log.setUseParentHandlers(false);
        try {
            try (SpectralDataset ds = SpectralDataset.create(path, "softfk",
                    "ISA", List.of(), List.of(), List.of(), List.of(),
                    List.of(knownSubj), List.of(danglingSample))) {
                assertEquals(1, ds.subjects().size());
                assertEquals(1, ds.samples().size());
            }
            boolean foundWarning = false;
            for (LogRecord r : captured) {
                if (r.getLevel() == Level.WARNING
                        && r.getMessage().contains("SAMP-DANGLING")
                        && r.getMessage().contains("SUBJ-MISSING")) {
                    foundWarning = true;
                    break;
                }
            }
            assertTrue(foundWarning,
                "soft-FK mismatch must log WARNING naming both sample and "
                + "unknown subject id; captured records: " + captured);
        } finally {
            log.removeHandler(capture);
            log.setLevel(oldLevel);
            log.setUseParentHandlers(oldUseParent);
        }

        // The dataset must still be readable with the dangling sample.
        try (SpectralDataset ds = SpectralDataset.open(path)) {
            Sample r = findSample(ds.samples(), "SAMP-DANGLING");
            assertNotNull(r, "dangling sample must persist despite soft-FK warning");
            assertEquals("SUBJ-MISSING", r.subjectExternalId());
        }
    }

    // ── attributes Map round-trip with special characters ───────────

    @Test
    void attributesMapMultiKeyAndSpecialCharsRoundTrip() {
        String path = tempDir.resolve("attrs.tio").toString();
        Map<String, String> attrs = new LinkedHashMap<>();
        attrs.put("alpha", "value with \"quotes\"");
        attrs.put("beta", "unicode-ok-Café");
        attrs.put("gamma", "");
        Subject s = new Subject("SUBJ-ATTRS", "p", "F", 2000, attrs);

        try (SpectralDataset ds = SpectralDataset.create(path, "attrs", "ISA",
                List.of(), List.of(), List.of(), List.of(),
                List.of(s), List.of())) {
            assertEquals(1, ds.subjects().size());
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            Subject r = findSubject(ds.subjects(), "SUBJ-ATTRS");
            assertNotNull(r);
            assertEquals("value with \"quotes\"", r.attributes().get("alpha"));
            assertEquals("unicode-ok-Café", r.attributes().get("beta"));
            assertEquals("", r.attributes().get("gamma"));
        }
    }

    /** {@link Subject#attributesJson} must emit keys in lexicographic
     *  order, matching Python json.dumps(..., sort_keys=True) — required
     *  for cross-language byte equivalence per design spec §6. */
    @Test
    void attributesJsonHasSortedKeys() {
        Map<String, String> input = new LinkedHashMap<>();
        input.put("zulu", "z");
        input.put("alpha", "a");
        input.put("mike", "m");
        Subject s = new Subject("SUBJ-SORT", "p", "F", 0, input);
        // Sorted lexicographically: alpha, mike, zulu.
        assertEquals(
            "{\"alpha\":\"a\",\"mike\":\"m\",\"zulu\":\"z\"}",
            s.attributesJson());

        Sample sa = new Sample("SAMP-SORT", "", "", 0, input);
        assertEquals(
            "{\"alpha\":\"a\",\"mike\":\"m\",\"zulu\":\"z\"}",
            sa.attributesJson());
    }

    /** Empty attributes Map must serialise to {@code "{}"} (not
     *  {@code ""}) so the on-disk slot is always valid JSON. */
    @Test
    void attributesJsonEmptyMap() {
        Subject s = new Subject("x", "", "", 0, Map.of());
        assertEquals("{}", s.attributesJson());
        Sample sa = new Sample("y", "", "", 0, Map.of());
        assertEquals("{}", sa.attributesJson());
    }

    // ── helpers ─────────────────────────────────────────────────────

    private static Subject findSubject(List<Subject> list, String externalId) {
        for (Subject s : list) {
            if (externalId.equals(s.externalId())) return s;
        }
        return null;
    }

    private static Sample findSample(List<Sample> list, String sampleId) {
        for (Sample s : list) {
            if (sampleId.equals(s.sampleId())) return s;
        }
        return null;
    }
}

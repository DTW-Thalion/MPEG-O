/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.Enums.AcquisitionMode;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Coverage-bridge test exercising the SQLite-provider attribute-fallback
 * JSON read path in {@link SpectralDataset#openViaProvider} —
 * specifically the
 * {@code readIdentificationsFromJson}/{@code readQuantificationsFromJson}/
 * {@code readProvenanceFromJson} branch trio that triggers the private
 * {@code parseIdentificationsJson}/{@code parseQuantificationsJson}/
 * {@code parseProvenanceJson} parsers. The HDF5-provider tests in the
 * existing corpus go through the compound-dataset path, never the
 * JSON-attribute fallback, so these parsers were at 0% line coverage.
 *
 * <p>The {@code sqlite://} URL scheme routes
 * {@link SpectralDataset#create} through
 * {@link SpectralDataset#createViaProviderMixed}, which writes
 * identifications/quantifications/provenance as JSON attributes on the
 * {@code /study} group (the SQLite provider has no native compound
 * dataset support). On re-open through {@code sqlite://},
 * {@code openViaProvider} reads those JSON attributes back via the
 * three {@code *FromJson} helpers.</p>
 *
 * <p>Per docs/superpowers/plans/2026-05-09-coverage-restoration.md J.6.</p>
 */
class SpectralDatasetSqliteJsonTest {

    private static AcquisitionRun makeRun() {
        int n = 2, peaks = 3;
        long[] offsets = new long[n];
        int[] lengths = new int[n];
        double[] rts = new double[n];
        int[] mls = new int[n];
        int[] pols = new int[n];
        double[] pmzs = new double[n];
        int[] pcs = new int[n];
        double[] bps = new double[n];
        for (int i = 0; i < n; i++) {
            offsets[i] = (long) i * peaks;
            lengths[i] = peaks;
            rts[i] = i;
            mls[i] = 1;
            pols[i] = 1;
            pmzs[i] = 0.0;
            pcs[i] = 0;
            bps[i] = 10.0;
        }
        SpectrumIndex idx = new SpectrumIndex(n, offsets, lengths, rts,
                mls, pols, pmzs, pcs, bps);
        Map<String, double[]> channels = new LinkedHashMap<>();
        double[] mz = new double[n * peaks];
        double[] intensity = new double[n * peaks];
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < peaks; j++) {
                mz[i * peaks + j] = 100.0 + j;
                intensity[i * peaks + j] = 1.0 + j;
            }
        }
        channels.put("mz", mz);
        channels.put("intensity", intensity);
        return new AcquisitionRun("run_0001", AcquisitionMode.MS1_DDA,
                idx, null, channels, List.of(), List.of(), null, 0);
    }

    @Test
    @DisplayName("SpectralDataset[sqlite]: identifications/quantifications/provenance JSON round-trip")
    void sqliteJsonAttributeRoundTrip(@TempDir Path tmp) {
        // sqlite:// URL routes through createViaProviderMixed, which
        // serializes identifications/quantifications/provenance as JSON
        // attributes on the /study group (SQLite has no compound-dataset
        // path, so JSON fallback is the canonical layout there).
        String url = "sqlite://" + tmp.resolve("json_round_trip.tio.sqlite");

        AcquisitionRun run = makeRun();
        List<Identification> idents = List.of(
            new Identification("run_0001", 0, "CHEBI:15377", 0.95,
                List.of("MS:1001143", "MS:1002338")),
            new Identification("run_0001", 1, "CHEBI:30742", 0.81,
                List.of("MS:1002493"))
        );
        // Two quantifications: one with normalization_method = null
        // (key omitted in JSON), one with a populated method (key
        // present). Drives both branches of parseQuantificationsJson.
        List<Quantification> quants = List.of(
            new Quantification("CHEBI:15377", "sample_001", 1234.5, null),
            new Quantification("CHEBI:30742", "sample_001", 0.001, "median")
        );
        // One provenance record with non-empty parameters/inputs/outputs
        // exercises every readXField branch in the parser.
        Map<String, String> params = new LinkedHashMap<>();
        params.put("threshold", "0.5");
        params.put("mode", "strict");
        ProvenanceRecord pr = new ProvenanceRecord(
            1700000000L, "TTI-O Java 1.0.0",
            params,
            List.of("file:///in.raw"),
            List.of("file:///out.tio"));
        List<ProvenanceRecord> prov = List.of(pr);

        // Write through the sqlite:// route — exercises the JSON-write
        // side of createViaProviderMixed (buildIdentificationsJson /
        // buildQuantificationsJson / buildProvenanceJson all fire here).
        try (SpectralDataset ds = SpectralDataset.create(
                url, "json-route", "ISA-JSON",
                List.of(run), idents, quants, prov)) {
            assertEquals("json-route", ds.title());
        }

        // Re-open through the same route — exercises the JSON-read
        // side: openViaProvider reads the *_json attributes and
        // dispatches to parseIdentificationsJson / parseQuantifications
        // Json / parseProvenanceJson.
        try (SpectralDataset ds = SpectralDataset.open(url)) {
            assertEquals("json-route", ds.title());
            assertEquals("ISA-JSON", ds.isaInvestigationId());

            // ── Identifications ───────────────────────────────────
            List<Identification> gotIdents = ds.identifications();
            assertEquals(2, gotIdents.size(),
                "both identifications survive JSON round-trip");
            assertEquals("CHEBI:15377", gotIdents.get(0).chemicalEntity());
            assertEquals(0, gotIdents.get(0).spectrumIndex());
            assertEquals(0.95, gotIdents.get(0).confidenceScore(), 1e-9);
            // evidence_chain → list-of-strings round-trip
            assertEquals(List.of("MS:1001143", "MS:1002338"),
                gotIdents.get(0).evidenceChain());
            assertEquals("CHEBI:30742", gotIdents.get(1).chemicalEntity());

            // ── Quantifications ───────────────────────────────────
            List<Quantification> gotQuants = ds.quantifications();
            assertEquals(2, gotQuants.size(),
                "both quantifications survive JSON round-trip");
            // First: null normalization_method (omitted in JSON,
            // recovered as null because parser sets norm = null when
            // key is absent OR value is empty).
            assertEquals("CHEBI:15377", gotQuants.get(0).chemicalEntity());
            assertEquals(1234.5, gotQuants.get(0).abundance(), 0.0);
            assertNull(gotQuants.get(0).normalizationMethod(),
                "missing normalization_method recovers as null");
            // Second: populated method round-trips verbatim.
            assertEquals("median", gotQuants.get(1).normalizationMethod());

            // ── Provenance ────────────────────────────────────────
            List<ProvenanceRecord> gotProv = ds.provenanceRecords();
            assertEquals(1, gotProv.size());
            ProvenanceRecord rt = gotProv.get(0);
            assertEquals(1700000000L, rt.timestampUnix());
            assertEquals("TTI-O Java 1.0.0", rt.software());
            // Parameters map — both keys round-trip with their string
            // values. (The parser preserves both insertion order and
            // value strings, but Map equality is order-independent.)
            assertEquals("0.5", rt.parameters().get("threshold"));
            assertEquals("strict", rt.parameters().get("mode"));
            // input_refs / output_refs round-trip as list-of-strings.
            assertEquals(List.of("file:///in.raw"), rt.inputRefs());
            assertEquals(List.of("file:///out.tio"), rt.outputRefs());
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // HDF5 path: quantifications with units → @quantification_units sidecar
    // ════════════════════════════════════════════════════════════════════
    //
    // Covers the {@code anyUnit} write branch in
    // {@link SpectralDataset#writeQuantifications(Hdf5Group, List)}: when
    // any quantification carries a non-empty unit, the writer emits a
    // sidecar JSON-array attribute {@code quantification_units} on the
    // /study group; the reader path in {@code readQuantifications}
    // parses it back to populate {@link Quantification#unit}.
    //
    // The existing
    // {@link SpectralDatasetTest#quantificationsRoundTrip} test uses the
    // 4-arg {@link Quantification} constructor (no unit), so the
    // {@code anyUnit} branch was 0% before this test landed.

    @Test
    @DisplayName("SpectralDataset[hdf5]: quantifications with units write/read sidecar attribute")
    void hdf5QuantificationUnitsRoundTrip(@TempDir Path tmp) {
        String path = tmp.resolve("quant_units.tio").toString();

        // Mix: one quant with unit, one without — the {@code anyUnit}
        // branch should fire on the first one. Also include an
        // embedded backslash + quote in a unit string to drive the
        // JSON escape branches in the writer.
        List<Quantification> quants = List.of(
            new Quantification("CHEBI:15377", "sample_A", 1234.5, "TIC", "ng/mL"),
            new Quantification("CHEBI:17234", "sample_A",   87.2, null,  ""),
            new Quantification("HMDB:1",      "sample_B",    1.0, "median",
                "back\\slash + quote\"")
        );

        try (SpectralDataset ds = SpectralDataset.create(path,
                "units test", null,
                List.of(), List.of(), quants, List.of())) {
            assertNotNull(ds);
        }

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            List<Quantification> read = ds.quantifications();
            assertEquals(3, read.size());
            assertEquals("ng/mL", read.get(0).unit(),
                "first quant unit should round-trip verbatim");
            // Empty/null unit → recovered as "" (Quantification compact
            // ctor coerces null → "").
            assertEquals("", read.get(1).unit(),
                "missing unit recovers as empty string");
            assertEquals("back\\slash + quote\"", read.get(2).unit(),
                "JSON-escaped unit chars round-trip verbatim");
        }
    }
}

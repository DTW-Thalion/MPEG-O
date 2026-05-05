/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.Identification;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.Quantification;
import global.thalion.ttio.SpectralDataset;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * v0.7 M51 — compound parity dumper. Reads an {@code .tio} file and
 * emits {@code /study/identifications}, {@code /study/quantifications},
 * and {@code /study/provenance} as deterministic JSON to stdout.
 *
 * <p>Output is byte-identical to the Python
 * {@code ttio.tools.dump_identifications} and Objective-C
 * {@code TtioDumpIdentifications} tools.</p>
 *
 * <p>Invoke via Maven:</p>
 * <pre>
 *   mvn -q exec:java -Dexec.mainClass=global.thalion.ttio.tools.DumpIdentifications \
 *       -Dexec.args="path/to/file.tio"
 * </pre>
 *
 * <p>Exit codes:</p>
 * <ul>
 *   <li>{@code 0} — wrote output successfully.</li>
 *   <li>{@code 1} — argument error.</li>
 *   <li>{@code 2} — open/read failure.</li>
 * </ul>
 *
 *
 */
public final class DumpIdentifications {

    private DumpIdentifications() {}

    static Map<String, Object> identificationRecord(Identification ident) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("chemical_entity", ident.chemicalEntity());
        m.put("confidence_score", ident.confidenceScore());
        m.put("evidence_chain", new ArrayList<>(ident.evidenceChain()));
        m.put("run_name", ident.runName());
        m.put("spectrum_index", (long) ident.spectrumIndex());
        return m;
    }

    static Map<String, Object> quantificationRecord(Quantification q) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("abundance", q.abundance());
        m.put("chemical_entity", q.chemicalEntity());
        m.put("normalization_method",
              q.normalizationMethod() != null ? q.normalizationMethod() : "");
        m.put("sample_ref", q.sampleRef());
        return m;
    }

    static Map<String, Object> provenanceRecord(ProvenanceRecord p) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("input_refs", new ArrayList<>(p.inputRefs()));
        m.put("output_refs", new ArrayList<>(p.outputRefs()));
        TreeMap<String, Object> params = new TreeMap<>();
        for (var e : p.parameters().entrySet()) {
            params.put(e.getKey(), e.getValue() != null ? e.getValue() : "");
        }
        m.put("parameters", params);
        m.put("software", p.software() != null ? p.software() : "");
        m.put("timestamp_unix", p.timestampUnix());
        return m;
    }

    /** Return the canonical JSON for the dataset at {@code path}. */
    public static String dump(String path) throws IOException {
        List<Map<String, Object>> idents = new ArrayList<>();
        List<Map<String, Object>> quants = new ArrayList<>();
        List<Map<String, Object>> provs  = new ArrayList<>();
        List<Map<String, Object>> msPerRun = new ArrayList<>();
        try (SpectralDataset ds = SpectralDataset.open(path)) {
            for (Identification i : ds.identifications()) {
                idents.add(identificationRecord(i));
            }
            for (Quantification q : ds.quantifications()) {
                quants.add(quantificationRecord(q));
            }
            for (ProvenanceRecord p : ds.provenanceRecords()) {
                provs.add(provenanceRecord(p));
            }
            // Per-run provenance, flattened across MS runs in sorted-
            // name order. Each record carries the run name and a per-
            // run sequence index for stable byte-parity across Python,
            // Java, and Objective-C dumpers.
            List<String> sortedNames =
                new ArrayList<>(ds.msRuns().keySet());
            java.util.Collections.sort(sortedNames);
            for (String runName : sortedNames) {
                var run = ds.msRuns().get(runName);
                List<ProvenanceRecord> chain = run.provenanceChain();
                for (int seq = 0; seq < chain.size(); seq++) {
                    Map<String, Object> rec = provenanceRecord(chain.get(seq));
                    rec.put("run", runName);
                    rec.put("seq", (long) seq);
                    msPerRun.add(rec);
                }
            }
        }
        Map<String, List<Map<String, Object>>> sections = new LinkedHashMap<>();
        sections.put("identifications", idents);
        sections.put("ms_per_run_provenance", msPerRun);
        sections.put("quantifications", quants);
        sections.put("provenance", provs);
        return CanonicalJson.formatTopLevel(sections);
    }

    public static void main(String[] args) {
        if (args.length != 1) {
            System.err.println(
                "usage: DumpIdentifications <path.tio>");
            System.exit(1);
            return;
        }
        String blob;
        try {
            blob = dump(args[0]);
        } catch (Exception e) {
            System.err.println("dump failed: " + e.getMessage());
            e.printStackTrace(System.err);
            System.exit(2);
            return;
        }
        try {
            System.out.write(blob.getBytes(StandardCharsets.UTF_8));
            System.out.flush();
        } catch (IOException e) {
            System.err.println("stdout write failed: " + e.getMessage());
            System.exit(2);
        }
    }
}

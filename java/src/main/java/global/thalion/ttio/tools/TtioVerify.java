/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.GenomicRun;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Java equivalent of the Objective-C {@code TtioVerify} CLI. Reads
 * a .tio file and prints a flat JSON summary that matches the ObjC
 * tool's output byte-for-byte (modulo whitespace), so a Python
 * cross-language harness can spawn both subprocesses and assert
 * structural equivalence.
 *
 * <p>Output schema (stable):</p>
 * <pre>
 * {
 *   "title": "...",
 *   "isa_investigation_id": "...",
 *   "ms_runs": {"run_0001": {"spectrum_count": 5}, ...},
 *   "genomic_runs": {"genomic_0001": {"read_count": 100,
 *                                      "reference_uri": "...",
 *                                      "platform": "...",
 *                                      "sample_name": "..."}, ...},
 *   "identification_count": N,
 *   "quantification_count": N,
 *   "provenance_count": N
 * }
 * </pre>
 *
 * <p>The {@code genomic_runs} block was added in M82.4 to drive the
 * cross-language conformance matrix; pre-M82 datasets emit it as an
 * empty object.</p>
 *
 * <p>Usage: {@code mvn exec:java -Dexec.mainClass=global.thalion.ttio.tools.TtioVerify -Dexec.args="path/to.tio"}</p>
 *
 * @since 0.9
 */
public final class TtioVerify {

    private TtioVerify() {}

    public static void main(String[] args) {
        if (args.length < 1) {
            System.err.println("usage: TtioVerify <path-to-.tio>");
            System.exit(2);
        }
        try (SpectralDataset ds = SpectralDataset.open(args[0])) {
            StringBuilder out = new StringBuilder("{");
            out.append("\"title\":").append(jsonEscape(ds.title())).append(",");
            out.append("\"isa_investigation_id\":")
               .append(jsonEscape(ds.isaInvestigationId())).append(",");

            out.append("\"ms_runs\":{");
            List<String> names = new ArrayList<>(ds.msRuns().keySet());
            Collections.sort(names);
            for (int i = 0; i < names.size(); i++) {
                String n = names.get(i);
                AcquisitionRun run = ds.msRuns().get(n);
                if (i > 0) out.append(",");
                out.append(jsonEscape(n))
                   .append(":{\"spectrum_count\":")
                   .append(run.spectrumCount())
                   .append("}");
            }
            out.append("},");

            out.append("\"genomic_runs\":{");
            List<String> gnames = new ArrayList<>(ds.genomicRuns().keySet());
            Collections.sort(gnames);
            for (int i = 0; i < gnames.size(); i++) {
                String n = gnames.get(i);
                GenomicRun gr = ds.genomicRuns().get(n);
                if (i > 0) out.append(",");
                out.append(jsonEscape(n))
                   .append(":{\"read_count\":").append(gr.readCount())
                   .append(",\"reference_uri\":").append(jsonEscape(gr.referenceUri()))
                   .append(",\"platform\":").append(jsonEscape(gr.platform()))
                   .append(",\"sample_name\":").append(jsonEscape(gr.sampleName()))
                   .append("}");
            }
            out.append("},");

            out.append("\"identification_count\":")
               .append(ds.identifications().size()).append(",");
            out.append("\"quantification_count\":")
               .append(ds.quantifications().size()).append(",");
            out.append("\"provenance_count\":")
               .append(ds.provenanceRecords().size());
            out.append("}");
            System.out.println(out);
        } catch (Exception e) {
            System.err.println("TtioVerify: failed to open " + args[0] + ": " + e.getMessage());
            System.exit(1);
        }
    }

    private static String jsonEscape(String s) {
        if (s == null) return "\"\"";
        StringBuilder sb = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n");  break;
                case '\r': sb.append("\\r");  break;
                case '\t': sb.append("\\t");  break;
                default:
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else          sb.append(c);
            }
        }
        sb.append('"');
        return sb.toString();
    }
}

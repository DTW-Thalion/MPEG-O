/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.tools;

import com.dtwthalion.mpgo.AcquisitionRun;
import com.dtwthalion.mpgo.SpectralDataset;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Java equivalent of the Objective-C {@code MpgoVerify} CLI. Reads
 * a .mpgo file and prints a flat JSON summary that matches the ObjC
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
 *   "identification_count": N,
 *   "quantification_count": N,
 *   "provenance_count": N
 * }
 * </pre>
 *
 * <p>Usage: {@code mvn exec:java -Dexec.mainClass=com.dtwthalion.mpgo.tools.MpgoVerify -Dexec.args="path/to.mpgo"}</p>
 *
 * @since 0.9
 */
public final class MpgoVerify {

    private MpgoVerify() {}

    public static void main(String[] args) {
        if (args.length < 1) {
            System.err.println("usage: MpgoVerify <path-to-.mpgo>");
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

            out.append("\"identification_count\":")
               .append(ds.identifications().size()).append(",");
            out.append("\"quantification_count\":")
               .append(ds.quantifications().size()).append(",");
            out.append("\"provenance_count\":")
               .append(ds.provenanceRecords().size());
            out.append("}");
            System.out.println(out);
        } catch (Exception e) {
            System.err.println("MpgoVerify: failed to open " + args[0] + ": " + e.getMessage());
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

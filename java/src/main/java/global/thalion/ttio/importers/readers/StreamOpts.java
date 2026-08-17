/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers.readers;

import java.nio.file.Path;
import java.util.Map;

/** The streaming knobs an importer accepts in its {@code opts} map (the
 *  {@code --extra k=v} pairs of {@code EncodeCli}): {@code reference}
 *  (FASTA path, enables REF_DIFF_V2), {@code embed_reference},
 *  {@code block_reads}, {@code block_bytes}, {@code legacy_whole_channel},
 *  {@code batch_reads}, {@code batch_spectra}. */
final class StreamOpts {
    private StreamOpts() {}

    static Path referencePath(Map<String, Object> opts) {
        Object v = opts.get("reference");
        if (v instanceof Path p) return p;
        if (v instanceof String s && !s.isEmpty()) return Path.of(s);
        return null;
    }

    static boolean flag(Map<String, Object> opts, String key) {
        Object v = opts.get(key);
        if (v instanceof Boolean b) return b;
        if (v instanceof String s) return s.equals("1") || s.equalsIgnoreCase("true") || s.equalsIgnoreCase("yes");
        return false;
    }

    static Integer intOpt(Map<String, Object> opts, String key) {
        Object v = opts.get(key);
        if (v instanceof Number n) return n.intValue();
        if (v instanceof String s && !s.isEmpty()) return Integer.parseInt(s.trim());
        return null;
    }

    static Long longOpt(Map<String, Object> opts, String key) {
        Object v = opts.get(key);
        if (v instanceof Number n) return n.longValue();
        if (v instanceof String s && !s.isEmpty()) return Long.parseLong(s.trim());
        return null;
    }

    static Integer blockReads(Map<String, Object> opts) { return intOpt(opts, "block_reads"); }
    static Long blockBytes(Map<String, Object> opts) { return longOpt(opts, "block_bytes"); }

    static int batchReads(Map<String, Object> opts) {
        Integer v = intOpt(opts, "batch_reads");
        return v != null ? v : global.thalion.ttio.importers.BamReader.DEFAULT_BATCH_READS;
    }

    static int batchSpectra(Map<String, Object> opts) {
        Integer v = intOpt(opts, "batch_spectra");
        return v != null ? v : global.thalion.ttio.importers.MzMLReader.DEFAULT_BATCH_SPECTRA;
    }
}

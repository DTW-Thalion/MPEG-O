/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.importers.readers.BamReaderAdapter;
import global.thalion.ttio.importers.readers.BrukerReaderAdapter;
import global.thalion.ttio.importers.readers.CramReaderAdapter;
import global.thalion.ttio.importers.readers.ImzMLReaderAdapter;
import global.thalion.ttio.importers.readers.JcampDxReaderAdapter;
import global.thalion.ttio.importers.readers.MzMLReaderAdapter;
import global.thalion.ttio.importers.readers.MzTabReaderAdapter;
import global.thalion.ttio.importers.readers.NmrMLReaderAdapter;
import global.thalion.ttio.importers.readers.SamReaderAdapter;
import global.thalion.ttio.importers.readers.ThermoRawReaderAdapter;
import global.thalion.ttio.importers.readers.WatersMassLynxReaderAdapter;

import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Encode-format registry: the single source of truth for the formats
 *  {@code ttio encode --format <fmt>} accepts and how each maps to a
 *  {@code .tio}. Each spec pairs a format with a {@link Reader} instance;
 *  {@link #encode} dispatches via {@code reader.read(...).write(output)}.
 *
 *  <p>{@code fasta} / {@code fastq} are intentionally NOT registered here:
 *  they keep their richer dedicated CLIs and {@code encode} delegates to
 *  those separately (see {@link #CLI_DELEGATED}).
 *
 *  <p>Mirrors Python {@code ttio.importers.registry} EXACTLY (the
 *  cross-language fence; see {@code RegistryParityTest}). */
public final class ImporterRegistry {

    private ImporterRegistry() {
    }

    /** Importers delegated to the dedicated CLIs rather than this registry. */
    public static final List<String> CLI_DELEGATED = List.of("fasta", "fastq");

    private static final List<FormatSpec> _SPECS = List.of(
        new FormatSpec("mzml", "mzML", List.of(".mzML", ".mzML.gz"), null,
            new MzMLReaderAdapter()),
        new FormatSpec("mztab", "mzTab", List.of(".mzTab", ".mztab"), null,
            new MzTabReaderAdapter()),
        new FormatSpec("imzml", "imzML", List.of(".imzML"), null,
            new ImzMLReaderAdapter()),
        new FormatSpec("nmrml", "nmrML", List.of(".nmrML"), null,
            new NmrMLReaderAdapter()),
        new FormatSpec("jcamp-dx", "JCAMP-DX", List.of(".jdx", ".dx", ".jcm"),
            null, new JcampDxReaderAdapter()),
        new FormatSpec("bruker-timstof", "Bruker timsTOF", List.of(".d"),
            "Bruker Python helper", new BrukerReaderAdapter()),
        new FormatSpec("waters-masslynx", "Waters MassLynx", List.of(".raw"),
            "masslynxraw", new WatersMassLynxReaderAdapter()),
        new FormatSpec("thermo-raw", "Thermo .raw", List.of(".raw"),
            "ThermoRawFileParser", new ThermoRawReaderAdapter()),
        // Java uses bundled htsjdk (no external samtools); cf. Python which shells out to samtools.
        new FormatSpec("bam", "BAM", List.of(".bam"), null,
            new BamReaderAdapter()),
        // Java uses bundled htsjdk (no external samtools); cf. Python which shells out to samtools.
        new FormatSpec("sam", "SAM", List.of(".sam"), null,
            new SamReaderAdapter()),
        // Java uses bundled htsjdk (no external samtools); cf. Python which shells out to samtools.
        new FormatSpec("cram", "CRAM", List.of(".cram"), null,
            new CramReaderAdapter()));

    private static final Map<String, FormatSpec> _BY_KEY = byKey(_SPECS);

    /** Aliases -&gt; canonical key. Lets users pass {@code "thermo"},
     *  {@code "raw"}, {@code "timstof"}, {@code "masslynx"}, etc. */
    private static final Map<String, String> _ALIASES = aliases();

    private static Map<String, FormatSpec> byKey(List<FormatSpec> specs) {
        Map<String, FormatSpec> m = new LinkedHashMap<>();
        for (FormatSpec s : specs) {
            m.put(s.key(), s);
        }
        return Map.copyOf(m);
    }

    private static Map<String, String> aliases() {
        Map<String, String> m = new LinkedHashMap<>();
        m.put("thermo", "thermo-raw");
        m.put("thermo.raw", "thermo-raw");
        m.put("raw", "thermo-raw");
        m.put("waters", "waters-masslynx");
        m.put("masslynx", "waters-masslynx");
        m.put("bruker", "bruker-timstof");
        m.put("timstof", "bruker-timstof");
        m.put("tdf", "bruker-timstof");
        m.put("jcamp", "jcamp-dx");
        m.put("jdx", "jcamp-dx");
        m.put("dx", "jcamp-dx");
        m.put("jcm", "jcamp-dx");
        return Map.copyOf(m);
    }

    /** Canonicalise a user-supplied format token (lowercase, alias-mapped). */
    public static String normalize(String fmt) {
        String key = (fmt == null ? "" : fmt).strip().toLowerCase(
            java.util.Locale.ROOT);
        return _ALIASES.getOrDefault(key, key);
    }

    public static boolean isRegistryFormat(String fmt) {
        return _BY_KEY.containsKey(normalize(fmt));
    }

    public static FormatSpec specFor(String fmt) {
        String key = normalize(fmt);
        FormatSpec spec = _BY_KEY.get(key);
        if (spec == null) {
            throw new UnknownFormatError(fmt);
        }
        return spec;
    }

    /** Canonical keys handled by this registry (sorted). */
    public static List<String> registryKeys() {
        return _BY_KEY.keySet().stream().sorted().toList();
    }

    /** All formats {@code ttio encode} accepts: registry + CLI-delegated. */
    public static List<String> supportedEncodeFormats() {
        List<String> all = new ArrayList<>(_BY_KEY.keySet());
        all.addAll(CLI_DELEGATED);
        return all.stream().distinct().sorted().toList();
    }

    /** Dispatch {@code inputs} -&gt; {@code output} {@code .tio} for a
     *  registry format. Raises {@link UnknownFormatError} for non-registry
     *  formats (the CLI handles the {@code fasta}/{@code fastq} delegation
     *  separately). */
    public static void encode(String fmt, List<String> inputs, Path output,
                              Map<String, Object> opts) throws IOException {
        specFor(fmt).reader().read(inputs, opts, null).write(output);
    }
}

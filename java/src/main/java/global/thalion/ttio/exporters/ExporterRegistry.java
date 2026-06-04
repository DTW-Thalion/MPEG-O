/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.exporters;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.exporters.writers.BamWriterAdapter;
import global.thalion.ttio.exporters.writers.CramWriterAdapter;
import global.thalion.ttio.exporters.writers.ImzMLWriterAdapter;
import global.thalion.ttio.exporters.writers.IsaWriterAdapter;
import global.thalion.ttio.exporters.writers.JcampDxWriterAdapter;
import global.thalion.ttio.exporters.writers.MzMLWriterAdapter;
import global.thalion.ttio.exporters.writers.MzTabWriterAdapter;
import global.thalion.ttio.exporters.writers.NmrMLWriterAdapter;

import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Export-format registry: the formats {@code ttio export --format <fmt>}
 *  accepts and how each maps a {@code .tio} layer to an output file. Each
 *  spec pairs a format with a {@link Writer} instance; {@link #export} opens
 *  the {@code .tio} and dispatches via {@code writer.write(ds, layer, output,
 *  opts)}.
 *
 *  <p>{@code fasta} / {@code fastq} keep their dedicated CLIs and are NOT
 *  registered here (see {@link #CLI_DELEGATED}).
 *
 *  <p>Mirrors Python {@code ttio.exporters.registry} EXACTLY (the
 *  cross-language fence; see {@code RegistryParityTest}). */
public final class ExporterRegistry {

    private ExporterRegistry() {
    }

    public static final List<String> CLI_DELEGATED = List.of("fasta", "fastq");

    private static final List<ExportSpec> _SPECS = List.of(
        new ExportSpec("mzml", "mzML", List.of(".mzML"), null,
            new MzMLWriterAdapter()),
        new ExportSpec("mztab", "mzTab", List.of(".mzTab", ".mztab"), null,
            new MzTabWriterAdapter()),
        new ExportSpec("nmrml", "nmrML", List.of(".nmrML"), null,
            new NmrMLWriterAdapter()),
        new ExportSpec("imzml", "imzML", List.of(".imzML"), null,
            new ImzMLWriterAdapter()),
        new ExportSpec("jcamp-dx", "JCAMP-DX", List.of(".jdx", ".dx", ".jcm"),
            null, new JcampDxWriterAdapter()),
        new ExportSpec("isa", "ISA-Tab/JSON", List.of(".zip", ".json"), null,
            new IsaWriterAdapter()),
        new ExportSpec("bam", "BAM", List.of(".bam", ".sam"), "samtools",
            new BamWriterAdapter()),
        new ExportSpec("cram", "CRAM", List.of(".cram"), "samtools",
            new CramWriterAdapter()));

    private static final Map<String, ExportSpec> _BY_KEY = byKey(_SPECS);

    private static final Map<String, String> _ALIASES = aliases();

    private static Map<String, ExportSpec> byKey(List<ExportSpec> specs) {
        Map<String, ExportSpec> m = new LinkedHashMap<>();
        for (ExportSpec s : specs) {
            m.put(s.key(), s);
        }
        return Map.copyOf(m);
    }

    private static Map<String, String> aliases() {
        Map<String, String> m = new LinkedHashMap<>();
        m.put("isa-tab", "isa");
        m.put("isatab", "isa");
        m.put("jcamp", "jcamp-dx");
        m.put("jdx", "jcamp-dx");
        m.put("dx", "jcamp-dx");
        m.put("jcm", "jcamp-dx");
        return Map.copyOf(m);
    }

    public static String normalize(String fmt) {
        String key = (fmt == null ? "" : fmt).strip().toLowerCase(
            java.util.Locale.ROOT);
        return _ALIASES.getOrDefault(key, key);
    }

    public static boolean isRegistryFormat(String fmt) {
        return _BY_KEY.containsKey(normalize(fmt));
    }

    public static ExportSpec specFor(String fmt) {
        String key = normalize(fmt);
        ExportSpec spec = _BY_KEY.get(key);
        if (spec == null) {
            throw new UnknownFormatError(fmt);
        }
        return spec;
    }

    public static List<String> registryKeys() {
        return _BY_KEY.keySet().stream().sorted().toList();
    }

    public static List<String> supportedExportFormats() {
        List<String> all = new ArrayList<>(_BY_KEY.keySet());
        all.addAll(CLI_DELEGATED);
        return all.stream().distinct().sorted().toList();
    }

    /** Open {@code tioPath} and serialize {@code layer} to {@code output} for
     *  a registry format. Raises {@link UnknownFormatError} for non-registry
     *  formats. */
    public static void export(String fmt, Path tioPath, String layer,
                              Path output, Map<String, Object> opts)
            throws IOException {
        ExportSpec spec = specFor(fmt);
        try (SpectralDataset ds = SpectralDataset.open(tioPath.toString())) {
            spec.writer().write(ds, layer, output, opts);
        }
    }
}

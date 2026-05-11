package global.thalion.ttio.browser.importers;

import java.io.IOException;
import java.io.InputStream;
import java.util.List;
import java.util.Properties;

import global.thalion.ttio.browser.importers.ImportFormatSpec.ExtraField;
import global.thalion.ttio.browser.importers.ImportFormatSpec.SourceKind;

public final class ImportFormatRegistry {

    private static final List<ImportFormatSpec> SPECS = buildSpecs();

    private ImportFormatRegistry() {}

    public static List<ImportFormatSpec> all() { return SPECS; }

    public static List<ImportFormatSpec> available() {
        return SPECS.stream().filter(ImportFormatSpec::fullyAvailable).toList();
    }

    private static List<ImportFormatSpec> buildSpecs() {
        Properties props = new Properties();
        try (InputStream in = ImportFormatRegistry.class
                .getResourceAsStream("/formats.properties")) {
            if (in != null) props.load(in);
        } catch (IOException ignored) {
        }
        return List.of(
            spec("mzML", "global.thalion.ttio.importers.MzMLReader",
                SourceKind.FILE, List.of(".mzML", ".mzML.gz"),
                ExtraField.NONE, props, null),
            spec("mzTab", "global.thalion.ttio.importers.MzTabReader",
                SourceKind.FILE, List.of(".mzTab", ".mztab"),
                ExtraField.MZTAB_DIALECT_DETECT, props, null),
            spec("imzML", "global.thalion.ttio.importers.ImzMLReader",
                SourceKind.FILE, List.of(".imzML"),
                ExtraField.NONE, props, null),
            spec("nmrML", "global.thalion.ttio.importers.NmrMLReader",
                SourceKind.FILE, List.of(".nmrML"),
                ExtraField.NONE, props, null),
            spec("JCAMP-DX", "global.thalion.ttio.importers.JcampDxReader",
                SourceKind.FILE, List.of(".jdx", ".dx", ".jcm"),
                ExtraField.NONE, props, null),
            spec("Bruker timsTOF", "global.thalion.ttio.importers.BrukerTDFReader",
                SourceKind.DIRECTORY, List.of(".d"),
                ExtraField.NONE, props, "Bruker Python helper"),
            spec("Waters MassLynx", "global.thalion.ttio.importers.WatersMassLynxReader",
                SourceKind.DIRECTORY, List.of(".raw"),
                ExtraField.NONE, props, "masslynxraw"),
            spec("Thermo .raw", "global.thalion.ttio.importers.ThermoRawReader",
                SourceKind.FILE, List.of(".raw"),
                ExtraField.NONE, props, "ThermoRawFileParser"),
            // v1.4.1: BAM/SAM/CRAM no longer require the samtools CLI on PATH.
            // The htsjdk swap (PR #76) replaced the subprocess with the
            // pure-Java SAM/BAM/CRAM library bundled in the JAR, so the
            // formats are always available.
            spec("BAM", "global.thalion.ttio.importers.BamReader",
                SourceKind.FILE, List.of(".bam"),
                ExtraField.BAM_REFERENCE, props, null),
            spec("SAM", "global.thalion.ttio.importers.SamReader",
                SourceKind.FILE, List.of(".sam"),
                ExtraField.NONE, props, null),
            spec("CRAM", "global.thalion.ttio.importers.CramReader",
                SourceKind.FILE, List.of(".cram"),
                ExtraField.CRAM_REFERENCE, props, null),
            spec("FASTA", "global.thalion.ttio.importers.FastaReader",
                SourceKind.FILE, List.of(".fa", ".fasta", ".fna", ".ffn", ".faa"),
                ExtraField.FASTA_TREAT_AS, props, null),
            spec("FASTQ", "global.thalion.ttio.importers.FastqReader",
                SourceKind.FILE, List.of(".fastq", ".fq", ".fastq.gz", ".fq.gz"),
                ExtraField.FASTQ_PHRED, props, null)
        );
    }

    private static ImportFormatSpec spec(String name, String fqn,
                                         SourceKind kind, List<String> exts,
                                         ExtraField extras, Properties props,
                                         String requiredBinary) {
        return new ImportFormatSpec(name, fqn, kind, exts, extras,
            props.getProperty("import." + name + ".description", "(no description)"),
            requiredBinary);
    }
}

package global.thalion.ttio.browser.exporters;

import java.io.IOException;
import java.io.InputStream;
import java.util.List;
import java.util.Properties;

import global.thalion.ttio.browser.exporters.ExportFormatSpec.Eligibility;
import global.thalion.ttio.browser.exporters.ExportFormatSpec.ExtraField;

public final class ExportFormatRegistry {

    private static final List<ExportFormatSpec> SPECS = buildSpecs();

    private ExportFormatRegistry() {}

    public static List<ExportFormatSpec> all() { return SPECS; }

    public static List<ExportFormatSpec> available() {
        return SPECS.stream()
            .filter(ExportFormatSpec::writerOnClasspath)
            .filter(ExportFormatSpec::binaryAvailable)
            .toList();
    }

    private static List<ExportFormatSpec> buildSpecs() {
        Properties props = new Properties();
        try (InputStream in = ExportFormatRegistry.class
                .getResourceAsStream("/formats.properties")) {
            if (in != null) props.load(in);
        } catch (IOException ignored) {
        }
        return List.of(
            spec("mzML (indexed)", "global.thalion.ttio.exporters.MzMLWriter",
                List.of(".mzML"),
                Eligibility.MS_RUNS_PRESENT, ExtraField.NONE, props, null),
            spec("mzTab", "global.thalion.ttio.exporters.MzTabWriter",
                List.of(".mzTab", ".mztab"),
                Eligibility.IDENTS_OR_QUANTS_PRESENT, ExtraField.MZTAB_DIALECT, props, null),
            spec("imzML", "global.thalion.ttio.exporters.ImzMLWriter",
                List.of(".imzML"),
                Eligibility.MS_IMAGE_PRESENT, ExtraField.IMZML_MODE, props, null),
            spec("nmrML", "global.thalion.ttio.exporters.NmrMLWriter",
                List.of(".nmrML"),
                Eligibility.NMR_RUNS_PRESENT, ExtraField.NONE, props, null),
            spec("JCAMP-DX", "global.thalion.ttio.exporters.JcampDxWriter",
                List.of(".jdx", ".dx"),
                Eligibility.RAMAN_OR_IR_OR_UVVIS_PRESENT,
                ExtraField.JCAMP_ENCODING, props, null),
            spec("ISA-Tab/JSON", "global.thalion.ttio.exporters.ISAExporter",
                List.of(".zip", ".json"),
                Eligibility.ALWAYS, ExtraField.NONE, props, null),
            spec("BAM", "global.thalion.ttio.exporters.BamWriter",
                List.of(".bam", ".sam"),
                Eligibility.GENOMIC_RUNS_PRESENT, ExtraField.BAM_OUTPUT, props, "samtools"),
            spec("CRAM", "global.thalion.ttio.exporters.CramWriter",
                List.of(".cram"),
                Eligibility.GENOMIC_RUNS_PRESENT, ExtraField.CRAM_REFERENCE, props, "samtools"),
            spec("FASTA (reference)", "global.thalion.ttio.exporters.FastaWriter",
                List.of(".fa", ".fasta", ".fna", ".fa.gz", ".fasta.gz"),
                Eligibility.REFERENCES_PRESENT, ExtraField.FASTA_LINE_WIDTH, props, null),
            spec("FASTA (reads)", "global.thalion.ttio.exporters.FastaWriter",
                List.of(".fa", ".fasta", ".fa.gz", ".fasta.gz"),
                Eligibility.GENOMIC_RUNS_PRESENT, ExtraField.FASTA_LINE_WIDTH, props, null),
            spec("FASTQ", "global.thalion.ttio.exporters.FastqWriter",
                List.of(".fastq", ".fq", ".fastq.gz", ".fq.gz"),
                Eligibility.GENOMIC_RUNS_PRESENT, ExtraField.FASTQ_PHRED, props, null)
        );
    }

    private static ExportFormatSpec spec(String name, String fqn,
                                         List<String> exts,
                                         Eligibility eligibility,
                                         ExtraField extras, Properties props,
                                         String requiredBinary) {
        return new ExportFormatSpec(name, fqn, exts, eligibility, extras,
            props.getProperty("export." + name + ".description", "(no description)"),
            requiredBinary);
    }
}

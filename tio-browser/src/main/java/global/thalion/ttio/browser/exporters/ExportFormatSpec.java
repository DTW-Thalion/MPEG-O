package global.thalion.ttio.browser.exporters;

import java.util.List;

/**
 * Single row of the {@link ExportFormatRegistry} matrix. Mirrors
 * {@code ImportFormatSpec} on the export side: name, target writer
 * class, file extension hints, an {@link Eligibility} predicate that
 * gates the row in the {@link ExportDialog}, and an {@link ExtraField}
 * marker the dialog uses to surface format-specific extras.
 */
public final class ExportFormatSpec {

    /** Pre-condition on the open dataset that the format requires. */
    public enum Eligibility {
        ALWAYS,
        MS_RUNS_PRESENT,
        NMR_RUNS_PRESENT,
        RAMAN_OR_IR_OR_UVVIS_PRESENT,
        GENOMIC_RUNS_PRESENT,
        REFERENCES_PRESENT,
        MS_IMAGE_PRESENT,
        IDENTS_OR_QUANTS_PRESENT
    }

    /** Which dialog extras pane (if any) the format triggers. */
    public enum ExtraField {
        NONE,
        MZTAB_DIALECT,
        IMZML_MODE,
        JCAMP_ENCODING,
        BAM_OUTPUT,
        CRAM_REFERENCE,
        FASTA_LINE_WIDTH,
        FASTQ_PHRED
    }

    public final String name;
    public final String writerClassFqn;
    public final List<String> fileExts;
    public final Eligibility eligibility;
    public final ExtraField extras;
    public final String description;

    public ExportFormatSpec(String name,
                            String writerClassFqn,
                            List<String> fileExts,
                            Eligibility eligibility,
                            ExtraField extras,
                            String description) {
        this.name = name;
        this.writerClassFqn = writerClassFqn;
        this.fileExts = List.copyOf(fileExts);
        this.eligibility = eligibility;
        this.extras = extras;
        this.description = description;
    }

    public boolean writerOnClasspath() {
        try {
            Class.forName(writerClassFqn);
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        }
    }

    @Override
    public String toString() {
        return name;
    }
}

package global.thalion.ttio.browser.importers;

import java.util.List;

import global.thalion.ttio.browser.diag.Diagnostics;

public final class ImportFormatSpec {

    public enum SourceKind { FILE, DIRECTORY }

    public enum ExtraField {
        NONE,
        FASTA_TREAT_AS,
        FASTQ_PHRED,
        CRAM_REFERENCE,
        BAM_REFERENCE,
        MZTAB_DIALECT_DETECT
    }

    public final String name;
    public final String readerClassFqn;
    public final SourceKind sourceKind;
    public final List<String> fileExts;
    public final ExtraField extras;
    public final String description;
    /** Diagnostics probe name this format depends on; {@code null} if none. */
    public final String requiredBinary;

    public ImportFormatSpec(String name,
                            String readerClassFqn,
                            SourceKind sourceKind,
                            List<String> fileExts,
                            ExtraField extras,
                            String description) {
        this(name, readerClassFqn, sourceKind, fileExts, extras, description, null);
    }

    public ImportFormatSpec(String name,
                            String readerClassFqn,
                            SourceKind sourceKind,
                            List<String> fileExts,
                            ExtraField extras,
                            String description,
                            String requiredBinary) {
        this.name = name;
        this.readerClassFqn = readerClassFqn;
        this.sourceKind = sourceKind;
        this.fileExts = List.copyOf(fileExts);
        this.extras = extras;
        this.description = description;
        this.requiredBinary = requiredBinary;
    }

    public boolean readerOnClasspath() {
        try {
            Class.forName(readerClassFqn);
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        }
    }

    /** @return {@code true} if the format's required binary is on PATH (per
     *  {@link Diagnostics#cached()}), or {@code true} if no binary is required. */
    public boolean binaryAvailable() {
        return requiredBinary == null || Diagnostics.isAvailable(requiredBinary);
    }

    /** @return {@code true} if both reader class is on classpath AND any
     *  required external binary is available. */
    public boolean fullyAvailable() {
        return readerOnClasspath() && binaryAvailable();
    }

    /** @return human-readable reason this format is greyed, or {@code null}
     *  if {@link #fullyAvailable()}. */
    public String unavailableReason() {
        if (!readerOnClasspath()) {
            return "Reader class not on classpath: " + readerClassFqn;
        }
        if (requiredBinary != null && !Diagnostics.isAvailable(requiredBinary)) {
            return "Requires `" + requiredBinary + "` on PATH";
        }
        return null;
    }

    @Override
    public String toString() {
        return name;
    }
}

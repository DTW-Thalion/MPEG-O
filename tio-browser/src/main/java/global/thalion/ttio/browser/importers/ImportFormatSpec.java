package global.thalion.ttio.browser.importers;

import java.util.List;

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

    public ImportFormatSpec(String name,
                            String readerClassFqn,
                            SourceKind sourceKind,
                            List<String> fileExts,
                            ExtraField extras,
                            String description) {
        this.name = name;
        this.readerClassFqn = readerClassFqn;
        this.sourceKind = sourceKind;
        this.fileExts = List.copyOf(fileExts);
        this.extras = extras;
        this.description = description;
    }

    public boolean readerOnClasspath() {
        try {
            Class.forName(readerClassFqn);
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

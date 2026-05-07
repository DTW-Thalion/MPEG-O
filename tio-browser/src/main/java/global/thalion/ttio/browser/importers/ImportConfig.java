package global.thalion.ttio.browser.importers;

import java.nio.file.Path;

/**
 * Aggregated wizard answers passed to {@link ImportTask}. All fields
 * are nullable except {@code sourcePath} and {@code targetTio};
 * extras are read only when the format's {@link ImportFormatSpec#extras}
 * dictates so.
 */
public final class ImportConfig {

    public enum FastaTreatAs { REFERENCE, UNALIGNED_READS }

    public final Path sourcePath;
    public final Path targetTio;
    public final String provider;
    public final String runName;
    public final String datasetTitle;

    public final FastaTreatAs fastaTreatAs;
    public final Integer fastqPhred;     // null = auto-detect
    public final Path bamReference;      // optional
    public final Path cramReference;     // required for CRAM

    public ImportConfig(Path sourcePath, Path targetTio,
                        String provider, String runName,
                        String datasetTitle,
                        FastaTreatAs fastaTreatAs,
                        Integer fastqPhred,
                        Path bamReference,
                        Path cramReference) {
        this.sourcePath = sourcePath;
        this.targetTio = targetTio;
        this.provider = provider == null ? "hdf5" : provider;
        this.runName = runName;
        this.datasetTitle = datasetTitle == null ? "" : datasetTitle;
        this.fastaTreatAs = fastaTreatAs == null ? FastaTreatAs.REFERENCE
                                                 : fastaTreatAs;
        this.fastqPhred = fastqPhred;
        this.bamReference = bamReference;
        this.cramReference = cramReference;
    }

    /** Minimal constructor for non-genomic formats with no extras. */
    public static ImportConfig basic(Path sourcePath, Path targetTio,
                                     String provider, String runName,
                                     String datasetTitle) {
        return new ImportConfig(sourcePath, targetTio, provider, runName,
            datasetTitle, null, null, null, null);
    }
}

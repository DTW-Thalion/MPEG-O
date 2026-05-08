package global.thalion.ttio.browser.exporters;

import java.nio.file.Path;

/**
 * Aggregated wizard answers passed to {@link ExportTask}. All extras
 * are nullable — they are only read for the format whose
 * {@link ExportFormatSpec#extras} requires them.
 */
public final class ExportConfig {

    public final Path targetPath;

    /** {@code "1.0"} (proteomics) or {@code "2.0.0-M"} (metabolomics). */
    public final String mzTabDialect;

    /** {@code "continuous"} or {@code "processed"}. */
    public final String imzMlMode;

    /** {@code "AFFN"}, {@code "PAC"}, {@code "SQZ"}, or {@code "DIF"}. */
    public final String jcampEncoding;

    /** When true, BAM row writes a SAM text file instead. */
    public final boolean bamSamOutput;

    /** Optional reference for BAM (passed through to samtools). */
    public final Path bamReference;

    /** Required reference for CRAM. */
    public final Path cramReference;

    /** FASTA wrap width in bytes, default 60. */
    public final int fastaLineWidth;

    /** {@code true} forces gzip; {@code false} forces raw; {@code null} = derive from extension. */
    public final Boolean gzipOutput;

    /** {@code 33} (default) or {@code 64} for FASTQ Phred offset. */
    public final int fastqPhred;

    /** Optional run-name selector when the dataset has multiple runs (null = first). */
    public final String selectedRunName;

    public ExportConfig(Path targetPath,
                        String mzTabDialect,
                        String imzMlMode,
                        String jcampEncoding,
                        boolean bamSamOutput,
                        Path bamReference,
                        Path cramReference,
                        int fastaLineWidth,
                        Boolean gzipOutput,
                        int fastqPhred,
                        String selectedRunName) {
        this.targetPath = targetPath;
        this.mzTabDialect = mzTabDialect == null ? "1.0" : mzTabDialect;
        this.imzMlMode = imzMlMode == null ? "continuous" : imzMlMode;
        this.jcampEncoding = jcampEncoding == null ? "AFFN" : jcampEncoding;
        this.bamSamOutput = bamSamOutput;
        this.bamReference = bamReference;
        this.cramReference = cramReference;
        this.fastaLineWidth = fastaLineWidth <= 0 ? 60 : fastaLineWidth;
        this.gzipOutput = gzipOutput;
        this.fastqPhred = (fastqPhred == 33 || fastqPhred == 64) ? fastqPhred : 33;
        this.selectedRunName = selectedRunName;
    }

    /** Minimal constructor for non-genomic formats with no extras. */
    public static ExportConfig basic(Path targetPath) {
        return new ExportConfig(targetPath, null, null, null, false,
            null, null, 60, null, 33, null);
    }
}

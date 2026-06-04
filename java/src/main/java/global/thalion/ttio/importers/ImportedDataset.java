package global.thalion.ttio.importers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Identification;
import global.thalion.ttio.IRImage;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.Quantification;
import global.thalion.ttio.RamanImage;
import global.thalion.ttio.Sample;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.Subject;
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.io.ProgressSink;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/** Normalized in-memory draft every importer produces; {@link #write} is
 *  the single dataset-write call site. Cross-language equivalent: Python
 *  {@code ttio.importers.imported_dataset.ImportedDataset}. */
public final class ImportedDataset {
    public String title = "";
    public String isaInvestigationId = "";
    public final List<AcquisitionRun> runs = new ArrayList<>();
    public final List<WrittenGenomicRun> genomicRuns = new ArrayList<>();
    public final List<Identification> identifications = new ArrayList<>();
    public final List<Quantification> quantifications = new ArrayList<>();
    public final List<ProvenanceRecord> provenance = new ArrayList<>();
    public final List<Subject> subjects = new ArrayList<>();
    public final List<Sample> samples = new ArrayList<>();
    public MSImage image;
    public RamanImage ramanImage;
    public IRImage irImage;

    /** Write this draft to {@code output} with no progress reporting. */
    public Path write(Path output) { return write(output, null); }

    /** Write this draft to {@code output} via the single image-aware
     *  {@link SpectralDataset#create} call site, optionally reporting
     *  per-section progress. Returns the written {@code .tio} path. */
    public Path write(Path output, ProgressSink progress) {
        return SpectralDataset.create(
            output.toString(),
            title.isEmpty() ? "imported" : title,
            isaInvestigationId,
            runs, genomicRuns,
            identifications, quantifications, provenance,
            subjects, samples,
            image, ramanImage, irImage,
            progress != null ? progress : ProgressSink.discard());
    }
}

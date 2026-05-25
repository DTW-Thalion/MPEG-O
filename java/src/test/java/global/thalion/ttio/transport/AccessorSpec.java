package global.thalion.ttio.transport;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.ReferenceImport;

import java.nio.file.Path;
import java.util.Arrays;

/** Enumerates every public accessor on {@link SpectralDataset} for
 *  parameterised round-trip testing. Stage 0 only wires REFERENCES;
 *  Stage 1 adds MS_RUNS, GENOMIC_RUNS, IMAGE, IDENTIFICATIONS,
 *  QUANTIFICATIONS, DATASET_PROVENANCE, SUBJECTS, SAMPLES,
 *  ENCRYPTION_ALGORITHM. */
public enum AccessorSpec {

    REFERENCES {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildReferenceOnly(tmp.resolve("ref.tio"));
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            if (a.references().size() != b.references().size()) {
                throw new AssertionError("reference count mismatch: "
                    + a.references().size() + " vs " + b.references().size());
            }
            a.references().forEach((uri, refA) -> {
                ReferenceImport refB = b.references().get(uri);
                if (refB == null) {
                    throw new AssertionError(
                        "missing reference " + uri + " in round-trip output");
                }
                // Per-chromosome name + sequence comparison.
                if (refA.chromosomes().size() != refB.chromosomes().size()) {
                    throw new AssertionError("chromosome count mismatch for "
                        + uri + ": " + refA.chromosomes().size()
                        + " vs " + refB.chromosomes().size());
                }
                for (int i = 0; i < refA.chromosomes().size(); i++) {
                    String nameA = refA.chromosomes().get(i);
                    String nameB = refB.chromosomes().get(i);
                    if (!nameA.equals(nameB)) {
                        throw new AssertionError("chromosome name mismatch at "
                            + uri + "[" + i + "]: '" + nameA + "' vs '" + nameB + "'");
                    }
                    byte[] seqA = refA.sequences().get(i);
                    byte[] seqB = refB.sequences().get(i);
                    if (!Arrays.equals(seqA, seqB)) {
                        throw new AssertionError("chromosome sequence mismatch at "
                            + uri + "[" + i + "] '" + nameA + "'");
                    }
                }
            });
        }
    };

    public abstract Path buildFixture(Path tmp) throws Exception;
    public abstract void assertContentEquals(SpectralDataset a, SpectralDataset b);
}

package global.thalion.ttio.browser.model;

import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Test;

import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

class DatasetTreeBuilderTest {

    @Test
    void minimalMsFixtureBuildsExpectedTree() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/minimal_ms.tio")
                    .toAbsolutePath().toString())) {
            DatasetTreeNode root = DatasetTreeBuilder.build(
                new OpenDataset("minimal_ms.tio", true, ds));

            assertEquals(TreeNodeKind.DATASET_ROOT, root.kind());

            DatasetTreeNode study = childOfKind(root, TreeNodeKind.STUDY_GROUP);
            DatasetTreeNode msRuns = childOfKind(study, TreeNodeKind.MS_RUNS_GROUP);
            assertEquals(1, msRuns.children().size());
            DatasetTreeNode oneRun = msRuns.children().get(0);
            assertEquals(TreeNodeKind.MS_RUN, oneRun.kind());

            assertNotNull(childOfKind(root, TreeNodeKind.FEATURE_FLAGS));
            assertNotNull(childOfKind(root, TreeNodeKind.ENCRYPTION));
        }
    }

    @Test
    void nmr1dFixtureExposesNmrRunsBranch() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../java/src/test/resources/ttio/nmr_1d.tio")
                    .toAbsolutePath().toString())) {
            DatasetTreeNode root = DatasetTreeBuilder.build(
                new OpenDataset("nmr_1d.tio", true, ds));
            DatasetTreeNode study = childOfKind(root, TreeNodeKind.STUDY_GROUP);
            DatasetTreeNode nmr = childOfKind(study, TreeNodeKind.NMR_RUNS_GROUP);
            assertNotNull(nmr);
            assertFalse(nmr.children().isEmpty());
            assertEquals(TreeNodeKind.NMR_RUN, nmr.children().get(0).kind());
        }
    }

    @Test
    void m82GenomicFixtureExposesGenomicRunsBranch() throws Exception {
        try (SpectralDataset ds = SpectralDataset.open(
                Paths.get("../python/tests/fixtures/genomic/m82_100reads.tio")
                    .toAbsolutePath().toString())) {
            DatasetTreeNode root = DatasetTreeBuilder.build(
                new OpenDataset("m82_100reads.tio", true, ds));
            DatasetTreeNode study = childOfKind(root, TreeNodeKind.STUDY_GROUP);
            DatasetTreeNode genomic = childOfKind(study, TreeNodeKind.GENOMIC_RUNS_GROUP);
            assertNotNull(genomic);
            assertFalse(genomic.children().isEmpty());
        }
    }

    private static DatasetTreeNode childOfKind(DatasetTreeNode parent, TreeNodeKind k) {
        return parent.children().stream()
            .filter(c -> c.kind() == k)
            .findFirst()
            .orElseThrow(() -> new AssertionError(
                "no " + k + " child of " + parent.kind()));
    }
}

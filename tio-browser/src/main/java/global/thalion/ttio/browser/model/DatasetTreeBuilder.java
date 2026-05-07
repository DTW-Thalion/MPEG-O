package global.thalion.ttio.browser.model;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.genomics.ReferenceImport;

import java.util.LinkedHashMap;
import java.util.Map;

public final class DatasetTreeBuilder {

    private DatasetTreeBuilder() {}

    public static DatasetTreeNode build(OpenDataset open) {
        String label = open.dataset().title();
        if (label == null || label.isEmpty()) {
            label = pathTail(open.path());
        }
        DatasetTreeNode root = new DatasetTreeNode(
            TreeNodeKind.DATASET_ROOT, label, null);

        DatasetTreeNode study = new DatasetTreeNode(
            TreeNodeKind.STUDY_GROUP, "/study", null);
        root.add(study);

        // Group AcquisitionRuns by their AcquisitionMode. Note: TreeNodeKind
        // includes RAMAN/IR/UV_VIS group/run kinds for forward-compatibility,
        // but the libttio AcquisitionMode enum currently only models
        // MS{1,2}_DDA / DIA / SRM / IMAGING / NMR_{1,2}D / GENOMIC_W{G,E}S.
        // Anything not NMR is grouped under MS_RUNS_GROUP.
        Map<TreeNodeKind, DatasetTreeNode> acqGroups = new LinkedHashMap<>();
        for (var entry : open.dataset().msRuns().entrySet()) {
            AcquisitionRun run = entry.getValue();
            TreeNodeKind groupKind = groupKindFor(run.acquisitionMode());
            DatasetTreeNode group = acqGroups.computeIfAbsent(groupKind,
                k -> new DatasetTreeNode(k, groupLabelFor(k), null));
            group.add(new DatasetTreeNode(
                runKindFor(groupKind), entry.getKey(), entry.getKey()));
        }
        for (DatasetTreeNode g : acqGroups.values()) study.add(g);

        if (!open.dataset().genomicRuns().isEmpty()) {
            DatasetTreeNode g = new DatasetTreeNode(
                TreeNodeKind.GENOMIC_RUNS_GROUP, "genomic_runs", null);
            for (var entry : open.dataset().genomicRuns().entrySet()) {
                g.add(new DatasetTreeNode(
                    TreeNodeKind.GENOMIC_RUN, entry.getKey(), entry.getKey()));
            }
            study.add(g);
        }

        if (!open.dataset().references().isEmpty()) {
            DatasetTreeNode refs = new DatasetTreeNode(
                TreeNodeKind.REFERENCES_GROUP, "references", null);
            for (var entry : open.dataset().references().entrySet()) {
                ReferenceImport r = entry.getValue();
                String lbl = entry.getKey() + " (" + r.chromosomes().size() + " chroms)";
                refs.add(new DatasetTreeNode(
                    TreeNodeKind.REFERENCE, lbl, entry.getKey()));
            }
            study.add(refs);
        }

        if (!open.dataset().identifications().isEmpty()) {
            study.add(new DatasetTreeNode(
                TreeNodeKind.IDENTIFICATIONS,
                "identifications (" + open.dataset().identifications().size() + ")",
                null));
        }
        if (!open.dataset().quantifications().isEmpty()) {
            study.add(new DatasetTreeNode(
                TreeNodeKind.QUANTIFICATIONS,
                "quantifications (" + open.dataset().quantifications().size() + ")",
                null));
        }
        if (!open.dataset().provenanceRecords().isEmpty()) {
            study.add(new DatasetTreeNode(
                TreeNodeKind.PROVENANCE,
                "provenance (" + open.dataset().provenanceRecords().size() + ")",
                null));
        }

        root.add(new DatasetTreeNode(
            TreeNodeKind.FEATURE_FLAGS, "feature_flags", null));
        root.add(new DatasetTreeNode(
            TreeNodeKind.ENCRYPTION,
            open.isEncrypted() ? "encryption (🔒)" : "encryption (🔓)",
            null));

        return root;
    }

    private static TreeNodeKind groupKindFor(AcquisitionMode m) {
        switch (m) {
            case NMR_1D:
            case NMR_2D:
                return TreeNodeKind.NMR_RUNS_GROUP;
            case MS1_DDA:
            case MS2_DDA:
            case DIA:
            case SRM:
            case IMAGING:
            default:
                return TreeNodeKind.MS_RUNS_GROUP;
        }
    }

    private static TreeNodeKind runKindFor(TreeNodeKind groupKind) {
        switch (groupKind) {
            case NMR_RUNS_GROUP:    return TreeNodeKind.NMR_RUN;
            case RAMAN_RUNS_GROUP:  return TreeNodeKind.RAMAN_RUN;
            case IR_RUNS_GROUP:     return TreeNodeKind.IR_RUN;
            case UV_VIS_RUNS_GROUP: return TreeNodeKind.UV_VIS_RUN;
            case MS_RUNS_GROUP:
            default:                return TreeNodeKind.MS_RUN;
        }
    }

    private static String groupLabelFor(TreeNodeKind groupKind) {
        switch (groupKind) {
            case NMR_RUNS_GROUP:    return "nmr_runs";
            case RAMAN_RUNS_GROUP:  return "raman_runs";
            case IR_RUNS_GROUP:     return "ir_runs";
            case UV_VIS_RUNS_GROUP: return "uv_vis_runs";
            case MS_RUNS_GROUP:
            default:                return "ms_runs";
        }
    }

    private static String pathTail(String path) {
        int slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
        return slash < 0 ? path : path.substring(slash + 1);
    }
}

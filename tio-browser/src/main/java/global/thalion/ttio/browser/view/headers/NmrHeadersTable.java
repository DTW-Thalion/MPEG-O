package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.NMRSpectrum;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;

import java.util.List;

public class NmrHeadersTable extends HeadersTableBase<NMRSpectrum> {

    private String currentSolvent = "";

    public NmrHeadersTable() {
        table.getColumns().add(col("idx",            NMRSpectrum::indexPosition));
        table.getColumns().add(col("nucleus",        NMRSpectrum::nucleusType));
        table.getColumns().add(col("freq (MHz)",     NMRSpectrum::spectrometerFrequencyMHz));
        table.getColumns().add(col("scan time (s)",  NMRSpectrum::scanTimeSeconds));
        table.getColumns().add(col("solvent",        s -> currentSolvent));
    }

    @Override public String title() { return "NMR Headers"; }

    @Override
    public boolean appliesTo(DatasetTreeNode s) {
        return s.kind() == TreeNodeKind.NMR_RUN;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        AcquisitionRun run = d.dataset().msRuns().get(selection.key());
        if (run == null) {
            currentSolvent = "";
            table.getItems().clear();
            return;
        }
        currentSolvent = run.solvent() == null ? "" : run.solvent();
        List<NMRSpectrum> rows = run.spectra().stream()
            .filter(NMRSpectrum.class::isInstance)
            .map(NMRSpectrum.class::cast)
            .toList();
        table.getItems().setAll(rows);
    }
}

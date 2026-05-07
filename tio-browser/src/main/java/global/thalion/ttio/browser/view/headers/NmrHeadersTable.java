package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.NMRSpectrum;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;

import java.util.ArrayList;
import java.util.List;

public class NmrHeadersTable extends HeadersTableBase<NMRSpectrum> {

    public NmrHeadersTable() {
        table.getColumns().add(col("idx",            NMRSpectrum::indexPosition));
        table.getColumns().add(col("nucleus",        NMRSpectrum::nucleusType));
        table.getColumns().add(col("freq (MHz)",     NMRSpectrum::spectrometerFrequencyMHz));
        table.getColumns().add(col("scan time (s)",  NMRSpectrum::scanTimeSeconds));
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
            table.getItems().clear();
            return;
        }
        List<NMRSpectrum> rows = new ArrayList<>(run.count());
        for (int i = 0; i < run.count(); i++) {
            Spectrum s = run.objectAtIndex(i);
            if (s instanceof NMRSpectrum nmr) rows.add(nmr);
        }
        table.getItems().setAll(rows);
    }
}

package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;

import java.util.ArrayList;
import java.util.List;

public class MsHeadersTable extends HeadersTableBase<MassSpectrum> {

    public MsHeadersTable() {
        table.getColumns().add(col("idx",            MassSpectrum::indexPosition));
        table.getColumns().add(col("scan time (s)",  MassSpectrum::scanTimeSeconds));
        table.getColumns().add(col("MS level",       MassSpectrum::msLevel));
        table.getColumns().add(col("polarity",       s -> s.polarity() == null
            ? "" : s.polarity().name()));
        table.getColumns().add(col("precursor m/z",  MassSpectrum::precursorMz));
        table.getColumns().add(col("precursor charge", MassSpectrum::precursorCharge));
        table.getColumns().add(col("activation",     s -> s.activationMethod() == null
            ? "" : s.activationMethod().name()));
    }

    @Override public String title() { return "MS Headers"; }

    @Override
    public boolean appliesTo(DatasetTreeNode s) {
        return s.kind() == TreeNodeKind.MS_RUN;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        AcquisitionRun run = d.dataset().msRuns().get(selection.key());
        if (run == null) {
            table.getItems().clear();
            return;
        }
        List<MassSpectrum> rows = new ArrayList<>(run.count());
        for (int i = 0; i < run.count(); i++) {
            Spectrum s = run.objectAtIndex(i);
            if (s instanceof MassSpectrum ms) rows.add(ms);
        }
        table.getItems().setAll(rows);
    }
}

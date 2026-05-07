package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;

import java.util.List;

public class MsHeadersTable extends HeadersTableBase<MassSpectrum> {

    private SpectrumIndex currentIndex;

    public MsHeadersTable() {
        table.getColumns().add(col("idx",              MassSpectrum::indexPosition));
        table.getColumns().add(col("scan time (s)",    MassSpectrum::scanTimeSeconds));
        table.getColumns().add(col("MS level",         MassSpectrum::msLevel));
        table.getColumns().add(col("polarity",         s -> s.polarity() == null
            ? "" : s.polarity().name()));
        table.getColumns().add(col("precursor m/z",    MassSpectrum::precursorMz));
        table.getColumns().add(col("precursor charge", MassSpectrum::precursorCharge));
        table.getColumns().add(col("base peak int.",   s -> currentIndex == null
            ? null : currentIndex.basePeakIntensityAt(s.indexPosition())));
        table.getColumns().add(col("activation",       s -> s.activationMethod() == null
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
            currentIndex = null;
            table.getItems().clear();
            return;
        }
        currentIndex = run.spectrumIndex();
        List<MassSpectrum> rows = run.spectra().stream()
            .filter(MassSpectrum.class::isInstance)
            .map(MassSpectrum.class::cast)
            .toList();
        table.getItems().setAll(rows);
    }
}

package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.IRSpectrum;
import global.thalion.ttio.RamanSpectrum;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.UVVisSpectrum;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;

import java.util.ArrayList;
import java.util.List;

/**
 * Combined headers table for Raman / IR / UV-Vis spectra. Row type is
 * {@link Spectrum}; columns dispatch on the runtime subtype because
 * the three modalities share an x/y axis shape but differ in units and
 * auxiliary fields (laser power vs IR mode vs path length).
 *
 * <p>Currently forward-compat only: the live {@code AcquisitionMode}
 * enum has no constants that map to {@link TreeNodeKind#RAMAN_RUN},
 * {@link TreeNodeKind#IR_RUN}, or {@link TreeNodeKind#UV_VIS_RUN}, so
 * {@link DatasetTreeBuilder} never produces these run kinds today.
 */
public class RamanHeadersTable extends HeadersTableBase<Spectrum> {

    public RamanHeadersTable() {
        table.getColumns().add(col("idx",     Spectrum::indexPosition));
        table.getColumns().add(col("type",    s -> s.getClass().getSimpleName()));
        table.getColumns().add(col("units",   RamanHeadersTable::unitsOf));
        table.getColumns().add(col("aux",     RamanHeadersTable::auxOf));
        table.getColumns().add(col("scan time (s)", Spectrum::scanTimeSeconds));
    }

    @Override public String title() { return "Spectroscopy Headers"; }

    @Override
    public boolean appliesTo(DatasetTreeNode s) {
        return s.kind() == TreeNodeKind.RAMAN_RUN
            || s.kind() == TreeNodeKind.IR_RUN
            || s.kind() == TreeNodeKind.UV_VIS_RUN;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        AcquisitionRun run = d.dataset().msRuns().get(selection.key());
        if (run == null) {
            table.getItems().clear();
            return;
        }
        List<Spectrum> rows = new ArrayList<>(run.count());
        for (int i = 0; i < run.count(); i++) {
            Spectrum s = run.objectAtIndex(i);
            if (s instanceof RamanSpectrum
                || s instanceof IRSpectrum
                || s instanceof UVVisSpectrum) {
                rows.add(s);
            }
        }
        table.getItems().setAll(rows);
    }

    private static String unitsOf(Spectrum s) {
        if (s instanceof RamanSpectrum || s instanceof IRSpectrum) return "cm⁻¹";
        if (s instanceof UVVisSpectrum) return "nm";
        return "";
    }

    private static String auxOf(Spectrum s) {
        if (s instanceof RamanSpectrum r) {
            return String.format("laser %.1f mW", r.laserPowerMw());
        }
        if (s instanceof IRSpectrum ir) {
            return ir.mode() == null ? "" : ir.mode().name();
        }
        if (s instanceof UVVisSpectrum uv) {
            return String.format("path %.2f cm", uv.pathLengthCm());
        }
        return "";
    }
}

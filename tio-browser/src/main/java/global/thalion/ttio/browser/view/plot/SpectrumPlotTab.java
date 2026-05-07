package global.thalion.ttio.browser.view.plot;

import global.thalion.ttio.Spectrum;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.browser.view.AbstractDetailTab;
import javafx.scene.Node;

/**
 * Detail-pane tab that hosts a {@link SpectrumPlotView}. Applies to any
 * spectrum-bearing run kind (MS / NMR / Raman / IR / UV-Vis); the tab
 * starts empty and is populated by the row-selection bridge from the
 * matching headers table.
 */
public class SpectrumPlotTab implements AbstractDetailTab {

    private final SpectrumPlotView view = new SpectrumPlotView();

    public SpectrumPlotView view() { return view; }

    public void render(Spectrum s) { view.render(s); }

    @Override public String title() { return "Plot"; }
    @Override public Node content() { return view.content(); }

    @Override
    public boolean appliesTo(DatasetTreeNode selection) {
        TreeNodeKind k = selection.kind();
        return k == TreeNodeKind.MS_RUN
            || k == TreeNodeKind.NMR_RUN
            || k == TreeNodeKind.RAMAN_RUN
            || k == TreeNodeKind.IR_RUN
            || k == TreeNodeKind.UV_VIS_RUN;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        // Run-level selection only resets the plot; the headers-table
        // row-selection bridge populates it. This avoids stale data
        // when the user switches runs.
        view.clear();
    }
}

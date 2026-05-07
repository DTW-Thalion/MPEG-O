package global.thalion.ttio.browser.view;

import global.thalion.ttio.Spectrum;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import javafx.scene.Node;

/**
 * Detail-pane tab hosting a {@link ChannelHexView}. Like
 * {@link global.thalion.ttio.browser.view.plot.SpectrumPlotTab}, it
 * applies to any spectrum-bearing run kind; the headers-table
 * row-selection bridge populates the view.
 */
public class ChannelHexTab implements AbstractDetailTab {

    private final ChannelHexView view = new ChannelHexView();

    public ChannelHexView view() { return view; }

    public void render(Spectrum s) { view.render(s); }

    @Override public String title() { return "Channels (hex)"; }
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
        view.clear();
    }
}

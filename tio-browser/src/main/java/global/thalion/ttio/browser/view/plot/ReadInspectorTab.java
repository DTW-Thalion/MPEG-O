package global.thalion.ttio.browser.view.plot;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.browser.view.AbstractDetailTab;
import global.thalion.ttio.genomics.AlignedRead;
import javafx.scene.Node;

/**
 * Detail-pane tab hosting a {@link ReadInspectorView}. Applies to
 * {@link TreeNodeKind#GENOMIC_RUN}; the
 * {@code GenomicHeadersTable.onRowSelected} bridge populates content
 * by calling {@link #render(AlignedRead)}. Mirrors the
 * {@code SpectrumPlotTab} pattern for analytical runs.
 */
public class ReadInspectorTab implements AbstractDetailTab {

    private final ReadInspectorView view = new ReadInspectorView();

    public ReadInspectorView view() { return view; }

    public void render(AlignedRead read) { view.render(read); }

    @Override public String title() { return "Read Inspector"; }
    @Override public Node content() { return view.content(); }

    @Override
    public boolean appliesTo(DatasetTreeNode selection) {
        return selection.kind() == TreeNodeKind.GENOMIC_RUN;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        view.clear();
    }
}

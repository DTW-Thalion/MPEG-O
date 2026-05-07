package global.thalion.ttio.browser.view.plot;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Chromatogram;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.browser.view.AbstractDetailTab;
import javafx.scene.Node;

/**
 * Detail-pane tab that renders a chromatogram trace when a CHROMATOGRAM
 * tree node is selected. The node's key is encoded by
 * {@link global.thalion.ttio.browser.model.DatasetTreeBuilder} as
 * {@code "<runKey>#<index>"}; this tab parses the key to resolve back
 * to the underlying {@link Chromatogram}.
 */
public class ChromatogramPlotTab implements AbstractDetailTab {

    private final ChromatogramPlotView view = new ChromatogramPlotView();

    public ChromatogramPlotView view() { return view; }

    @Override public String title() { return "Chromatogram"; }
    @Override public Node content() { return view.content(); }

    @Override
    public boolean appliesTo(DatasetTreeNode selection) {
        return selection.kind() == TreeNodeKind.CHROMATOGRAM;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        String key = selection.key();
        if (key == null) {
            view.clear();
            return;
        }
        int hash = key.indexOf('#');
        if (hash < 0) {
            view.clear();
            return;
        }
        String runKey = key.substring(0, hash);
        int chromIdx;
        try {
            chromIdx = Integer.parseInt(key.substring(hash + 1));
        } catch (NumberFormatException e) {
            view.clear();
            return;
        }
        AcquisitionRun run = d.dataset().msRuns().get(runKey);
        if (run == null || chromIdx < 0
                || chromIdx >= run.chromatograms().size()) {
            view.clear();
            return;
        }
        view.render(run.chromatograms().get(chromIdx));
    }
}

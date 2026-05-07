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

    /**
     * Render the given read, or a "(read codec unavailable)" placeholder
     * when {@code read} is {@code null} — typically because
     * {@code GenomicRowAdapter.full()} caught an
     * {@link UnsatisfiedLinkError} from the native codec path. The
     * underlying cause lives in
     * {@link global.thalion.ttio.browser.util.NativeLibraryLoader#lastError()}.
     */
    public void render(AlignedRead read) {
        if (read == null) {
            view.renderPlaceholder(buildJniUnavailableMessage());
            return;
        }
        view.render(read);
    }

    private static String buildJniUnavailableMessage() {
        Throwable cause = global.thalion.ttio.browser.util.NativeLibraryLoader.lastError();
        StringBuilder sb = new StringBuilder("Read materialisation unavailable.\n\n");
        sb.append("This .tio likely uses NAME_TOKENIZED_V2 / REF_DIFF_V2 codecs\n");
        sb.append("which require the libttio_rans_jni native library.\n");
        if (cause != null) {
            sb.append("\nLoader error: ").append(cause.getClass().getSimpleName())
              .append(": ").append(cause.getMessage());
        }
        sb.append("\n\nThe rest of the dataset (tree, headers, identifications,\n"
              + "quantifications, references, etc.) is unaffected.");
        return sb.toString();
    }

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

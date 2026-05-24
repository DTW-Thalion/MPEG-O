/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.shell.containers.UnifiedContainerNode;
import global.thalion.ttio.browser.util.Units;
import javafx.geometry.Insets;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;

/**
 * Metadata-and-actions panel shown when the user selects a
 * {@link UnifiedContainerNode.ServerContainer} in the unified container tree.
 *
 * <p>Displays the container URI and human-readable size, together with four
 * action buttons: Download, Selective Download, Export (server-side), and
 * Run Pipeline. Each button's action is registered via the corresponding
 * {@code on*(Runnable)} setter.</p>
 *
 * <p>Intentionally not an {@code AbstractDetailTab} — the selection model
 * for unified container tree nodes differs from the inner dataset-tree model.</p>
 */
public final class ServerContainerOverviewTab {

    private final VBox root = new VBox(12);
    private final Label uriLabel  = new Label();
    private final Label sizeLabel = new Label();
    private final Button downloadBtn         = new Button("Download…");
    private final Button selectiveDownloadBtn = new Button("Selective download…");
    private final Button serverExportBtn     = new Button("Export (server-side)…");
    private final Button runPipelineBtn      = new Button("Run pipeline…");

    public ServerContainerOverviewTab() {
        root.setPadding(new Insets(16));
        HBox actions = new HBox(8, downloadBtn, selectiveDownloadBtn,
            serverExportBtn, runPipelineBtn);
        root.getChildren().addAll(uriLabel, sizeLabel, actions);
    }

    /** Returns the root layout region for embedding in a parent container. */
    public Region node() { return root; }

    /**
     * Updates the URI and size labels to reflect the supplied container.
     * Safe to call on the JavaFX application thread only.
     */
    public void update(UnifiedContainerNode.ServerContainer c) {
        uriLabel.setText("URI: " + c.uri());
        sizeLabel.setText("Size: " + Units.humanBytes(c.sizeBytes()));
    }

    public Button downloadButton()          { return downloadBtn; }
    public Button selectiveDownloadButton() { return selectiveDownloadBtn; }
    public Button serverExportButton()      { return serverExportBtn; }
    public Button runPipelineButton()       { return runPipelineBtn; }

    public void onDownload(Runnable r)          { downloadBtn.setOnAction(e -> r.run()); }
    public void onSelectiveDownload(Runnable r) { selectiveDownloadBtn.setOnAction(e -> r.run()); }
    public void onServerExport(Runnable r)      { serverExportBtn.setOnAction(e -> r.run()); }
    public void onRunPipeline(Runnable r)       { runPipelineBtn.setOnAction(e -> r.run()); }
}

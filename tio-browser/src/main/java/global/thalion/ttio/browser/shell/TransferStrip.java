/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell;

import global.thalion.ttio.browser.progress.ProgressFormatter;
import global.thalion.ttio.browser.progress.ProgressReport;
import global.thalion.ttio.browser.util.Units;
import global.thalion.ttio.browser.workbench.Transfer;
import global.thalion.ttio.browser.workbench.TransferKind;
import global.thalion.ttio.browser.workbench.TransferManager;
import javafx.application.Platform;
import javafx.geometry.Pos;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;

import java.util.List;

/**
 * Always-visible bottom strip summarising in-flight transfers.
 * Auto-hides (visible=false, managed=false) when no transfers are
 * in the RUNNING state.
 */
public final class TransferStrip {

    private final TransferManager manager;
    private final Label summary = new Label("");
    private final Button viewAll = new Button("view all");
    private final HBox root;
    private Runnable onViewAll = () -> {};

    public TransferStrip(TransferManager manager) {
        this.manager = manager;
        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        this.root = new HBox(8, summary, spacer, viewAll);
        root.setAlignment(Pos.CENTER_LEFT);
        root.setPrefHeight(32);
        root.getStyleClass().add("transfer-strip");
        viewAll.setOnAction(e -> onViewAll.run());
        manager.addQueueListener(() -> Platform.runLater(this::refresh));
        manager.addProgressListener(r -> Platform.runLater(this::refresh));
        refresh();
    }

    public Region node() { return root; }
    public Label label() { return summary; }
    public Button viewAllButtonForTest() { return viewAll; }
    public void onViewAll(Runnable r) { this.onViewAll = r == null ? () -> {} : r; }

    private void refresh() {
        List<Transfer> active = manager.activeTransfers();
        if (active.isEmpty()) {
            root.setVisible(false);
            root.setManaged(false);
            return;
        }
        root.setVisible(true);
        root.setManaged(true);
        if (active.size() == 1) {
            Transfer t = active.get(0);
            ProgressReport r = t.lastReport();
            String arrow = (t.kind() == TransferKind.UPLOAD) ? "↑" : "↓";
            if (r == null) {
                summary.setText(arrow + " " + basename(t.localPath())
                    + " — starting…");
            } else {
                summary.setText(arrow + " " + basename(t.localPath()) + "  "
                    + ProgressFormatter.line(r, System.currentTimeMillis()));
            }
        } else {
            double up = 0, down = 0;
            for (Transfer t : active) {
                ProgressReport r = t.lastReport();
                if (r == null || Double.isNaN(r.rateBytesPerSec())) continue;
                if (t.kind() == TransferKind.UPLOAD) up += r.rateBytesPerSec();
                else down += r.rateBytesPerSec();
            }
            summary.setText(active.size() + " transfers active · ↑ "
                + Units.humanRate(up) + " · ↓ " + Units.humanRate(down));
        }
    }

    private static String basename(String path) {
        if (path == null) return "(unknown)";
        int slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
        return slash >= 0 ? path.substring(slash + 1) : path;
    }
}

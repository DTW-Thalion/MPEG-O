/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.view;

import javafx.geometry.Insets;
import javafx.geometry.Pos;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;

/**
 * Empty-state CTA panel shown when the user selects the Local root node
 * in the unified container tree.
 *
 * <p>Intentionally not an {@code AbstractDetailTab} — the selection model
 * for unified container tree nodes differs from the inner dataset-tree model.</p>
 */
public final class LocalRootInfoTab {

    private final VBox root = new VBox(16);
    private final Button openBtn   = new Button("Open file…");
    private final Button encodeBtn = new Button("Encode…");
    private final Button importBtn = new Button("Import…");
    private final Label headline   = new Label("Local files");
    private final Label hint       = new Label("Open a .tio you already have, or bring in new data.");

    public LocalRootInfoTab() {
        root.setAlignment(Pos.CENTER);
        root.setPadding(new Insets(24));
        root.getChildren().addAll(headline, hint, openBtn, encodeBtn, importBtn);
        for (Button b : new Button[]{openBtn, encodeBtn, importBtn}) {
            b.setMinWidth(180);
        }
    }

    /** Returns the root layout region for embedding in a parent container. */
    public Region node() { return root; }

    public Button openButton()   { return openBtn; }
    public Button encodeButton() { return encodeBtn; }
    public Button importButton() { return importBtn; }

    public void onOpen(Runnable r)   { openBtn.setOnAction(e -> r.run()); }
    public void onEncode(Runnable r) { encodeBtn.setOnAction(e -> r.run()); }
    public void onImport(Runnable r) { importBtn.setOnAction(e -> r.run()); }
}

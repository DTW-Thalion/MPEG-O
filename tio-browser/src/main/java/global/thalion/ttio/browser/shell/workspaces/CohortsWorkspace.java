/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.shell.Workspace;
import global.thalion.ttio.browser.workbench.CohortQueryBuilder;
import global.thalion.ttio.browser.workbench.ConnectionListener;
import global.thalion.ttio.browser.workbench.ConnectionManager;
import global.thalion.ttio.browser.workbench.LoginDialog;
import javafx.application.Platform;
import javafx.geometry.Pos;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.layout.Region;
import javafx.scene.layout.StackPane;
import javafx.scene.layout.VBox;
import javafx.stage.Window;

public final class CohortsWorkspace implements Workspace {

    private final StackPane root = new StackPane();
    private final VBox offlineCta = new VBox(12);
    private final Button connectBtn = new Button("Connect…");
    private final Region builderContent;
    private final ConnectionManager manager;
    private final ConnectionListener listener;

    public CohortsWorkspace(Window owner) {
        this.manager = ConnectionManager.instance();
        this.builderContent =
            CohortQueryBuilder.buildContent(manager, owner);
        offlineCta.setAlignment(Pos.CENTER);
        offlineCta.getChildren().addAll(
            new Label("Connect to a workbench server to build cohort queries."),
            connectBtn);
        connectBtn.setOnAction(e ->
            new LoginDialog(owner).showAndConnect(s -> {}));
        root.getChildren().addAll(builderContent, offlineCta);
        refresh();
        this.listener = (s, m) -> Platform.runLater(this::refresh);
        manager.addListener(listener);
    }

    public String key()      { return "cohorts"; }
    public String tooltip()  { return "Cohorts"; }
    public String iconText() { return "🔬"; }
    public Region node()     { return root; }
    public void onShow()     {}
    public void onHide()     {}

    public VBox connectCtaForTest()      { return offlineCta; }
    public Region builderRegionForTest() { return builderContent; }

    private void refresh() {
        boolean online = manager.isConnected();
        offlineCta.setVisible(!online); offlineCta.setManaged(!online);
        builderContent.setVisible(online); builderContent.setManaged(online);
    }
}

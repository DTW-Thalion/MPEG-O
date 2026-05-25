/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.shell.Workspace;
import global.thalion.ttio.browser.workbench.ConnectionManager;
import global.thalion.ttio.browser.workbench.JobMonitor;
import global.thalion.ttio.browser.workbench.PipelineLauncher;
import global.thalion.ttio.browser.workbench.SessionLauncher;
import global.thalion.ttio.browser.workbench.SessionList;
import javafx.geometry.Insets;
import javafx.geometry.Orientation;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.control.SplitPane;
import javafx.scene.layout.BorderPane;
import javafx.scene.layout.Region;
import javafx.stage.Window;

/**
 * Workspace that embeds the job-monitor table and session-list table
 * side-by-side in a vertical split. "New job…" and "New session…" buttons
 * open the respective launcher modals.
 */
public final class JobsWorkspace implements Workspace {

    private final SplitPane root = new SplitPane();
    private final Button newJob = new Button("New job…");
    private final Button newSession = new Button("New session…");
    private final Region jobsContent;
    private final Region sessionsContent;

    public JobsWorkspace(Window owner) {
        jobsContent = JobMonitor.buildContent(ConnectionManager.instance(), owner);
        sessionsContent = SessionList.buildContent(ConnectionManager.instance(), owner);

        BorderPane jobsHeader = new BorderPane();
        jobsHeader.setLeft(new Label("Jobs"));
        jobsHeader.setRight(newJob);
        jobsHeader.setPadding(new Insets(8));
        BorderPane jobsPane = new BorderPane(jobsContent);
        jobsPane.setTop(jobsHeader);

        BorderPane sessionsHeader = new BorderPane();
        sessionsHeader.setLeft(new Label("Interactive sessions"));
        sessionsHeader.setRight(newSession);
        sessionsHeader.setPadding(new Insets(8));
        BorderPane sessionsPane = new BorderPane(sessionsContent);
        sessionsPane.setTop(sessionsHeader);

        root.setOrientation(Orientation.VERTICAL);
        root.getItems().addAll(jobsPane, sessionsPane);
        root.setDividerPositions(0.60);

        newJob.setOnAction(e -> new PipelineLauncher(owner).show());
        newSession.setOnAction(e -> new SessionLauncher(owner).show());
    }

    @Override public String key()      { return "jobs"; }
    @Override public String tooltip()  { return "Jobs & Sessions"; }
    @Override public String iconText() { return "⚙"; }
    @Override public Region node()     { return root; }
    @Override public void onShow()     {}
    @Override public void onHide()     {}

    // Test-only accessors
    public Button newJobButtonForTest()     { return newJob; }
    public Button newSessionButtonForTest() { return newSession; }
    public Region jobsContentForTest()      { return jobsContent; }
    public Region sessionsContentForTest()  { return sessionsContent; }
}

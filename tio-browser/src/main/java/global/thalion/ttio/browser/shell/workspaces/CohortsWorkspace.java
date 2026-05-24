package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.shell.Workspace;
import javafx.scene.control.Label;
import javafx.scene.layout.Region;
import javafx.scene.layout.StackPane;

public final class CohortsWorkspace implements Workspace {
    private final StackPane root = new StackPane(new Label(
        "Cohorts workspace (Stage 5 wires this up)"));
    public String key()      { return "cohorts"; }
    public String tooltip()  { return "Cohorts"; }
    public String iconText() { return "🔬"; }
    public Region node()     { return root; }
    public void onShow()     {}
    public void onHide()     {}
}

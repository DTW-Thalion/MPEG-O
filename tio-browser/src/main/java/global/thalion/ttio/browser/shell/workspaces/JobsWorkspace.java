package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.shell.Workspace;
import javafx.scene.control.Label;
import javafx.scene.layout.Region;
import javafx.scene.layout.StackPane;

public final class JobsWorkspace implements Workspace {
    private final StackPane root = new StackPane(new Label(
        "Jobs & Sessions workspace (Stage 4 wires this up)"));
    public String key()      { return "jobs"; }
    public String tooltip()  { return "Jobs & Sessions"; }
    public String iconText() { return "⚙"; }
    public Region node()     { return root; }
    public void onShow()     {}
    public void onHide()     {}
}

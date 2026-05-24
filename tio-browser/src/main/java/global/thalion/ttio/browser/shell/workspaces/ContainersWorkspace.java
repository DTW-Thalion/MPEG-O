package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.shell.Workspace;
import javafx.scene.control.Label;
import javafx.scene.layout.Region;
import javafx.scene.layout.StackPane;

public final class ContainersWorkspace implements Workspace {
    private final StackPane root = new StackPane(new Label(
        "Containers workspace (Stage 6 wires up the unified tree)"));
    public String key()      { return "containers"; }
    public String tooltip()  { return "Containers"; }
    public String iconText() { return "📁"; }
    public Region node()     { return root; }
    public void onShow()     {}
    public void onHide()     {}
}

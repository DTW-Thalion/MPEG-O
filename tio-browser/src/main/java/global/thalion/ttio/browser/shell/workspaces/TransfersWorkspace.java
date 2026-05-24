package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.shell.Workspace;
import javafx.scene.control.Label;
import javafx.scene.layout.Region;
import javafx.scene.layout.StackPane;

public final class TransfersWorkspace implements Workspace {
    private final StackPane root = new StackPane(new Label(
        "Transfers workspace (Stage 3 wires this up)"));
    public String key()      { return "transfers"; }
    public String tooltip()  { return "Transfers"; }
    public String iconText() { return "⇅"; }
    public Region node()     { return root; }
    public void onShow()     {}
    public void onHide()     {}
}

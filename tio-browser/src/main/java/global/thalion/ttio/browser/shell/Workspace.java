package global.thalion.ttio.browser.shell;

import javafx.scene.layout.Region;

public interface Workspace {
    /** Stable identifier, e.g. {@code "containers"}. */
    String key();
    /** Tooltip text shown on the rail icon. */
    String tooltip();
    /** Single-character glyph shown on the rail button. */
    String iconText();
    /** The workspace's root content, built once and reused. */
    Region node();
    /** Called when the workspace becomes the active one. */
    void onShow();
    /** Called when leaving the workspace. */
    void onHide();
}

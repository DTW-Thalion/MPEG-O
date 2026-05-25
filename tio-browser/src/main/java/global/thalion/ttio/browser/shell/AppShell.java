package global.thalion.ttio.browser.shell;

import global.thalion.ttio.browser.workbench.ConnectionManager;
import global.thalion.ttio.browser.workbench.StatusIndicator;
import global.thalion.ttio.browser.workbench.TransferManager;
import javafx.geometry.Pos;
import javafx.scene.control.Label;
import javafx.scene.layout.BorderPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Top-level shell: header bar + activity rail + active workspace
 * + bottom transfer strip. Construct via {@link #create(List)} (or
 * {@link #createForTest} for explicit managers) and add
 * {@link #root()} to a Scene.
 */
public final class AppShell {

    private final BorderPane root = new BorderPane();
    private final HBox header;
    private final ActivityRail rail;
    private final TransferStrip strip;
    private final StatusIndicator statusIndicator;
    private final Map<String, Workspace> workspaces;
    private String currentKey;

    private AppShell(List<Workspace> workspaces,
                     ConnectionManager cm,
                     TransferManager tm) {
        this.workspaces = new LinkedHashMap<>();
        for (Workspace w : workspaces) this.workspaces.put(w.key(), w);
        this.statusIndicator = new StatusIndicator(cm);
        this.header = buildHeader();
        this.rail = new ActivityRail(workspaces);
        this.strip = new TransferStrip(tm);
        this.strip.onViewAll(() -> rail.select("transfers"));

        root.setTop(header);
        root.setLeft(rail.node());
        root.setBottom(strip.node());
        rail.onSelect(this::switchTo);
        switchTo(rail.selectedKey());
    }

    public static AppShell create(List<Workspace> workspaces) {
        return new AppShell(workspaces,
            ConnectionManager.instance(),
            TransferManager.instance());
    }

    public static AppShell createForTest(List<Workspace> workspaces,
                                          ConnectionManager cm,
                                          TransferManager tm) {
        return new AppShell(workspaces, cm, tm);
    }

    public BorderPane root()                 { return root; }
    public HBox header()                     { return header; }
    public ActivityRail rail()               { return rail; }
    public TransferStrip transferStrip()     { return strip; }
    public StatusIndicator statusIndicator() { return statusIndicator; }

    public Workspace currentWorkspaceByKey(String key) {
        return workspaces.get(key);
    }

    public Workspace currentWorkspace() {
        return workspaces.get(currentKey);
    }

    private void switchTo(String key) {
        Workspace next = workspaces.get(key);
        if (next == null) return;
        if (currentKey != null && !currentKey.equals(key)) {
            workspaces.get(currentKey).onHide();
        }
        currentKey = key;
        root.setCenter(next.node());
        next.onShow();
    }

    private HBox buildHeader() {
        Label title = new Label("tio-browser");
        title.getStyleClass().add("app-title");
        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox h = new HBox(12, title, spacer, statusIndicator.node());
        h.setAlignment(Pos.CENTER_LEFT);
        h.setPrefHeight(36);
        h.getStyleClass().add("app-header");
        return h;
    }
}

package global.thalion.ttio.browser;

import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.shell.AppShell;
import global.thalion.ttio.browser.shell.workspaces.CohortsWorkspace;
import global.thalion.ttio.browser.shell.workspaces.ContainersWorkspace;
import global.thalion.ttio.browser.shell.workspaces.JobsWorkspace;
import global.thalion.ttio.browser.shell.workspaces.TransfersWorkspace;
import global.thalion.ttio.browser.view.DatasetTreeView;
import global.thalion.ttio.browser.view.DetailPane;
import javafx.application.Platform;
import javafx.scene.Scene;
import javafx.scene.control.Menu;
import javafx.scene.control.MenuBar;
import javafx.scene.control.MenuItem;
import javafx.scene.control.SeparatorMenuItem;
import javafx.scene.layout.BorderPane;
import javafx.scene.layout.VBox;
import javafx.stage.Stage;

import java.util.List;

public class MainWindow {

    private Stage stage;
    private BorderPane root;
    private AppShell shell;
    private MenuItem openItem, encodeItem, importItem, exportItem,
        saveAsItem, closeItem, exitItem;
    private Menu openRecentMenu;
    private MenuItem aboutItem, userGuideItem, diagnosticsItem;

    public void show(Stage primaryStage) {
        this.stage = primaryStage;
        this.shell = AppShell.create(List.of(
            new ContainersWorkspace(),
            new CohortsWorkspace(),
            new JobsWorkspace(primaryStage),
            new TransfersWorkspace(primaryStage)));
        MenuBar menuBar = buildMenuBar();
        this.root = new BorderPane();
        VBox topStack = new VBox(menuBar, shell.root().getTop());
        root.setTop(topStack);
        root.setLeft(shell.root().getLeft());
        root.setCenter(shell.root().getCenter());
        root.setBottom(shell.root().getBottom());
        Scene scene = new Scene(root, 1280, 800);
        scene.getStylesheets().add(
            getClass().getResource("/css/tio-browser.css").toExternalForm());
        primaryStage.setScene(scene);
        primaryStage.setTitle("tio-browser");
        primaryStage.show();
        wireMenuActions();
        // Re-route rail switching to keep the shell's center node in
        // sync after the re-parenting above:
        shell.rail().onSelect(k -> root.setCenter(shell.currentWorkspaceByKey(k).node()));
        // Fire-and-forget startup probe so Import/Export dialogs aren't
        // empty when first opened. Same pattern as old MainWindow.
        Thread probeThread = new Thread(() -> {
            try { global.thalion.ttio.browser.diag.Diagnostics.probeAll(); }
            catch (Throwable t) {
                java.util.logging.Logger.getLogger(MainWindow.class.getName())
                    .log(java.util.logging.Level.WARNING, "Startup diagnostics probe failed", t);
            }
        }, "diagnostics-startup-probe");
        probeThread.setDaemon(true);
        probeThread.start();
    }

    private MenuBar buildMenuBar() {
        Menu fileMenu = new Menu("File");
        openItem = new MenuItem("Open…");
        openRecentMenu = new Menu("Open Recent");
        encodeItem = new MenuItem("Encode…");
        importItem = new MenuItem("Import…");
        exportItem = new MenuItem("Export…");
        saveAsItem = new MenuItem("Save As…");
        closeItem = new MenuItem("Close");
        exitItem = new MenuItem("Exit");
        fileMenu.getItems().addAll(openItem, openRecentMenu, new SeparatorMenuItem(),
            encodeItem, importItem, exportItem, saveAsItem, new SeparatorMenuItem(),
            closeItem, exitItem);

        Menu helpMenu = new Menu("Help");
        aboutItem = new MenuItem("About");
        userGuideItem = new MenuItem("User guide");
        diagnosticsItem = new MenuItem("Diagnostics…");
        helpMenu.getItems().addAll(aboutItem, userGuideItem, diagnosticsItem);

        return new MenuBar(fileMenu, helpMenu);
    }

    private void wireMenuActions() {
        Runnable noop = () -> {};
        openItem.setOnAction(e -> {
            shell.rail().select("containers");
            containers().openFile(stage);
        });
        encodeItem.setOnAction(e -> noop.run());
        importItem.setOnAction(e -> noop.run());
        exportItem.setOnAction(e -> noop.run());
        saveAsItem.setOnAction(e -> containers().saveAs(stage));
        closeItem.setOnAction(e -> containers().closeDataset());
        aboutItem.setOnAction(e -> noop.run());
        userGuideItem.setOnAction(e -> noop.run());
        diagnosticsItem.setOnAction(e ->
            global.thalion.ttio.browser.diag.DiagnosticsDialog.show(stage));
        exitItem.setOnAction(e -> Platform.exit());
    }

    public BorderPane root() { return root; }
    public AppShell shell()  { return shell; }
    public Stage stage()     { return stage; }

    private ContainersWorkspace containers() {
        return (ContainersWorkspace) shell.currentWorkspaceByKey("containers");
    }

    public OpenDataset currentDataset()                         { return containers().currentDataset(); }
    public DatasetTreeView tree()                               { return containers().tree(); }
    public DetailPane detail()                                  { return containers().detail(); }
    public void loadDataset(String path, boolean readOnly)      { containers().loadDataset(path, readOnly); }
    public javafx.scene.control.Label statusLabel()            { return containers().statusLabel(); }

    // Test-only accessors preserved for existing tests:
    MenuItem openMenuItem()        { return openItem; }
    MenuItem closeMenuItem()       { return closeItem; }
    MenuItem exitMenuItem()        { return exitItem; }
    MenuItem diagnosticsMenuItem() { return diagnosticsItem; }
}

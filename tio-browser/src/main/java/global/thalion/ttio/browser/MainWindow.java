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
import javafx.scene.input.KeyCombination;
import javafx.scene.input.TransferMode;
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
        ContainersWorkspace containers = new ContainersWorkspace(primaryStage);
        TransfersWorkspace transfers = new TransfersWorkspace(primaryStage);
        // Wire Transfers' Start-new dialog to prefill the source from the
        // currently-open local dataset, if any.
        transfers.setSourceSupplier(() -> {
            var ds = containers.currentDataset();
            if (ds == null || ds.path() == null) return null;
            return java.nio.file.Paths.get(ds.path());
        });
        this.shell = AppShell.create(List.of(
            containers,
            new CohortsWorkspace(primaryStage),
            new JobsWorkspace(primaryStage),
            transfers));
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
        wireDragDrop(scene);
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
        openItem.setAccelerator(KeyCombination.keyCombination("Shortcut+O"));
        openRecentMenu = new Menu("Open Recent");
        openRecentMenu.setOnShowing(e -> rebuildRecentSubmenu());
        encodeItem = new MenuItem("Encode…");
        encodeItem.setAccelerator(KeyCombination.keyCombination("Shortcut+E"));
        importItem = new MenuItem("Import…");
        exportItem = new MenuItem("Export…");
        saveAsItem = new MenuItem("Save As…");
        closeItem = new MenuItem("Close");
        closeItem.setAccelerator(KeyCombination.keyCombination("Shortcut+W"));
        exitItem = new MenuItem("Exit");
        exitItem.setAccelerator(KeyCombination.keyCombination("Shortcut+Q"));
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

    private void rebuildRecentSubmenu() {
        openRecentMenu.getItems().clear();
        java.util.List<String> paths = containers().recentFiles();
        if (paths.isEmpty()) {
            MenuItem empty = new MenuItem("(no recent files)");
            empty.setDisable(true);
            openRecentMenu.getItems().add(empty);
            return;
        }
        for (String p : paths) {
            MenuItem item = new MenuItem(p);
            item.setOnAction(e -> {
                shell.rail().select("containers");
                containers().loadDataset(p, true);
            });
            openRecentMenu.getItems().add(item);
        }
    }

    private void wireMenuActions() {
        Runnable noop = () -> {};
        openItem.setOnAction(e -> {
            shell.rail().select("containers");
            containers().openFile(stage);
        });
        encodeItem.setOnAction(e -> containers().encodeAction());
        importItem.setOnAction(e -> containers().importAction());
        exportItem.setOnAction(e -> noop.run());
        saveAsItem.setOnAction(e -> containers().saveAs(stage));
        closeItem.setOnAction(e -> containers().closeDataset());
        aboutItem.setOnAction(e -> noop.run());
        userGuideItem.setOnAction(e -> noop.run());
        diagnosticsItem.setOnAction(e ->
            global.thalion.ttio.browser.diag.DiagnosticsDialog.show(stage));
        exitItem.setOnAction(e -> Platform.exit());
    }

    private void wireDragDrop(Scene scene) {
        scene.setOnDragOver(event -> {
            if (event.getDragboard().hasFiles()) {
                event.acceptTransferModes(TransferMode.COPY);
            }
            event.consume();
        });
        scene.setOnDragDropped(event -> {
            var db = event.getDragboard();
            boolean success = false;
            if (db.hasFiles() && !db.getFiles().isEmpty()) {
                shell.rail().select("containers");
                containers().handleDrop(db.getFiles().get(0));
                success = true;
            }
            event.setDropCompleted(success);
            event.consume();
        });
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

package global.thalion.ttio.browser;

import global.thalion.ttio.browser.model.DatasetOpenTask;
import global.thalion.ttio.browser.model.DatasetTreeBuilder;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.view.ChannelHexTab;
import global.thalion.ttio.browser.view.DatasetTreeView;
import global.thalion.ttio.browser.view.DetailPane;
import global.thalion.ttio.browser.view.EncryptionTab;
import global.thalion.ttio.browser.view.FeatureFlagsTab;
import global.thalion.ttio.browser.view.IdentificationsTab;
import global.thalion.ttio.browser.view.ProvenanceTab;
import global.thalion.ttio.browser.view.QuantificationsTab;
import global.thalion.ttio.browser.view.ReferenceTab;
import global.thalion.ttio.browser.view.headers.GenomicHeadersTable;
import global.thalion.ttio.browser.view.headers.MsHeadersTable;
import global.thalion.ttio.browser.view.headers.NmrHeadersTable;
import global.thalion.ttio.browser.view.headers.RamanHeadersTable;
import global.thalion.ttio.browser.view.overview.OverviewTab;
import global.thalion.ttio.browser.view.plot.ChromDistributionView;
import global.thalion.ttio.browser.view.plot.ChromatogramPlotTab;
import global.thalion.ttio.browser.view.plot.ReadInspectorTab;
import global.thalion.ttio.browser.view.plot.SpectrumPlotTab;
import javafx.geometry.Orientation;
import javafx.scene.Scene;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.FileChooser;
import javafx.stage.Stage;

import java.io.File;

public class MainWindow {

    private Stage stage;
    private BorderPane root;
    private Label statusBarLabel;
    private SplitPane mainSplit;
    private StackPane treeContainer;
    private StackPane detailContainer;

    private MenuItem openItem, closeItem, saveAsItem, exitItem;
    private MenuItem importItem, exportItem, downloadItem, uploadItem, diagnosticsItem;
    private MenuItem workbenchConnectItem, workbenchDisconnectItem, workbenchStatusItem;
    private MenuItem workbenchContainersItem;
    private MenuItem workbenchUploadItem, workbenchDownloadItem, workbenchTransfersItem;
    private MenuItem workbenchCohortItem;
    private MenuItem workbenchPipelinesItem, workbenchJobsItem;

    private DatasetTreeView treeView;
    private DetailPane detailPane;
    private OpenDataset currentDataset;
    private global.thalion.ttio.browser.workbench.StatusIndicator workbenchStatusIndicator;

    public void show(Stage primaryStage) {
        this.stage = primaryStage;
        this.root = new BorderPane();

        root.setTop(buildTopBars());
        root.setCenter(buildSplit());
        root.setBottom(buildStatusBar());

        Scene scene = new Scene(root, 1280, 800);
        scene.getStylesheets().add(
            getClass().getResource("/css/tio-browser.css").toExternalForm());
        primaryStage.setScene(scene);
        scene.setOnDragOver(e -> {
            if (e.getDragboard().hasFiles()) {
                e.acceptTransferModes(javafx.scene.input.TransferMode.COPY);
            }
        });
        scene.setOnDragDropped(e -> {
            boolean success = false;
            if (e.getDragboard().hasFiles()) {
                java.io.File f = e.getDragboard().getFiles().get(0);
                if (f.getName().toLowerCase(java.util.Locale.ROOT).endsWith(".tio")) {
                    loadDataset(f.toString(), true);
                    success = true;
                } else {
                    String sniffed =
                        global.thalion.ttio.browser.importers.FormatSniffer
                            .sniffFile(f.toPath());
                    var dlg = new global.thalion.ttio.browser.importers
                        .ImportDialog(primaryStage);
                    dlg.preSelectFormat(sniffed);
                    dlg.preSelectSource(f.toPath());
                    dlg.showAndImport(target -> loadDataset(target.toString(), false));
                    success = true;
                }
            }
            e.setDropCompleted(success);
            e.consume();
        });
        primaryStage.setTitle("tio-browser");
        primaryStage.show();
        wireFileActions();
        // Fire-and-forget: kick the binary-probe cache so Import/Export
        // dialogs don't show every binary-gated format as "(unavailable)"
        // until the user opens Diagnostics. Daemon thread so it never
        // blocks app exit; failures are logged and ignored — probe
        // failure must not break the app.
        Thread probeThread = new Thread(() -> {
            try {
                global.thalion.ttio.browser.diag.Diagnostics.probeAll();
            } catch (Throwable t) {
                java.util.logging.Logger
                    .getLogger(MainWindow.class.getName())
                    .log(java.util.logging.Level.WARNING,
                         "Startup diagnostics probe failed", t);
            }
        }, "diagnostics-startup-probe");
        probeThread.setDaemon(true);
        probeThread.start();
    }

    private VBox buildTopBars() {
        VBox box = new VBox(buildMenuBar(), buildToolBar());
        return box;
    }

    private MenuBar buildMenuBar() {
        Menu fileMenu = new Menu("File");
        openItem = new MenuItem("Open…");
        closeItem = new MenuItem("Close");
        saveAsItem = new MenuItem("Save As…");
        exitItem = new MenuItem("Exit");
        fileMenu.getItems().addAll(openItem, closeItem, new SeparatorMenuItem(),
            saveAsItem, new SeparatorMenuItem(), exitItem);

        Menu importMenu = new Menu("Import");
        importItem = new MenuItem("Import…");
        importMenu.getItems().add(importItem);

        Menu exportMenu = new Menu("Export");
        exportItem = new MenuItem("Export…");
        exportMenu.getItems().add(exportItem);

        Menu transportMenu = new Menu("Transport");
        downloadItem = new MenuItem("Download from server…");
        uploadItem = new MenuItem("Upload to server…");
        transportMenu.getItems().addAll(downloadItem, uploadItem);

        Menu workbenchMenu = new Menu("Workbench");
        workbenchConnectItem = new MenuItem("Connect…");
        workbenchDisconnectItem = new MenuItem("Disconnect");
        workbenchStatusItem = new MenuItem("Status…");
        workbenchContainersItem = new MenuItem("Browse containers…");
        workbenchUploadItem = new MenuItem("Upload to workbench…");
        workbenchDownloadItem = new MenuItem("Download from workbench…");
        workbenchTransfersItem = new MenuItem("Transfers…");
        workbenchCohortItem = new MenuItem("Cohort query…");
        workbenchPipelinesItem = new MenuItem("Launch pipeline…");
        workbenchJobsItem = new MenuItem("Jobs…");
        workbenchMenu.getItems().addAll(workbenchConnectItem,
            workbenchDisconnectItem, new SeparatorMenuItem(),
            workbenchContainersItem,
            workbenchUploadItem, workbenchDownloadItem, workbenchTransfersItem,
            new SeparatorMenuItem(),
            workbenchCohortItem,
            workbenchPipelinesItem, workbenchJobsItem,
            new SeparatorMenuItem(), workbenchStatusItem);

        Menu toolsMenu = new Menu("Tools");
        diagnosticsItem = new MenuItem("Diagnostics…");
        toolsMenu.getItems().add(diagnosticsItem);

        Menu helpMenu = new Menu("Help");
        helpMenu.getItems().add(new MenuItem("About"));

        return new MenuBar(fileMenu, importMenu, exportMenu, transportMenu,
                          workbenchMenu, toolsMenu, helpMenu);
    }

    private ToolBar buildToolBar() {
        Button openBtn = new Button("Open");
        openBtn.setOnAction(e -> openItem.fire());
        Button saveAsBtn = new Button("Save As");
        saveAsBtn.setOnAction(e -> saveAsItem.fire());
        Button importBtn = new Button("Import…");
        importBtn.setOnAction(e -> importItem.fire());
        Button exportBtn = new Button("Export…");
        exportBtn.setOnAction(e -> exportItem.fire());
        Button downloadBtn = new Button("Download…");
        downloadBtn.setOnAction(e -> downloadItem.fire());
        Button uploadBtn = new Button("Upload…");
        uploadBtn.setOnAction(e -> uploadItem.fire());
        Button diagnosticsBtn = new Button("Diagnostics");
        diagnosticsBtn.setOnAction(e -> diagnosticsItem.fire());
        return new ToolBar(openBtn, saveAsBtn, new Separator(), importBtn,
            exportBtn, new Separator(), downloadBtn, uploadBtn,
            new Separator(), diagnosticsBtn);
    }

    private SplitPane buildSplit() {
        mainSplit = new SplitPane();
        mainSplit.setOrientation(Orientation.HORIZONTAL);
        treeView = new DatasetTreeView();
        detailPane = new DetailPane();
        detailPane.register(new OverviewTab());
        MsHeadersTable msHeaders = new MsHeadersTable();
        NmrHeadersTable nmrHeaders = new NmrHeadersTable();
        RamanHeadersTable ramanHeaders = new RamanHeadersTable();
        SpectrumPlotTab plotTab = new SpectrumPlotTab();
        ChannelHexTab channelHexTab = new ChannelHexTab();
        // Bridge headers row-selection → SpectrumPlotTab.render +
        // ChannelHexTab.render. The Plot / Channels tabs themselves
        // only reset on run-level selection; the headers tables drive
        // the actual content.
        msHeaders.onRowSelected(spec -> {
            plotTab.render(spec);
            channelHexTab.render(spec);
        });
        nmrHeaders.onRowSelected(spec -> {
            plotTab.render(spec);
            channelHexTab.render(spec);
        });
        ramanHeaders.onRowSelected(spec -> {
            plotTab.render(spec);
            channelHexTab.render(spec);
        });
        detailPane.register(msHeaders);
        detailPane.register(nmrHeaders);
        detailPane.register(ramanHeaders);
        // Phase 7 — genomic detail panes
        GenomicHeadersTable genomicHeaders = new GenomicHeadersTable();
        ReadInspectorTab readInspectorTab = new ReadInspectorTab();
        genomicHeaders.onRowSelected(row -> readInspectorTab.render(row.full()));
        detailPane.register(genomicHeaders);
        detailPane.register(readInspectorTab);
        detailPane.register(new ChromDistributionView());
        detailPane.register(new ReferenceTab());
        // Analytical extras
        detailPane.register(plotTab);
        detailPane.register(channelHexTab);
        detailPane.register(new ChromatogramPlotTab());
        detailPane.register(new IdentificationsTab());
        detailPane.register(new QuantificationsTab());
        detailPane.register(new ProvenanceTab());
        detailPane.register(new FeatureFlagsTab());
        detailPane.register(new EncryptionTab());
        treeView.onSelected(node -> detailPane.onSelection(node));
        treeContainer = new StackPane(treeView.control());
        treeContainer.setMinWidth(240);
        detailContainer = new StackPane(detailPane.control());
        mainSplit.getItems().addAll(treeContainer, detailContainer);
        mainSplit.setDividerPositions(0.30);
        return mainSplit;
    }

    private HBox buildStatusBar() {
        statusBarLabel = new Label("(no file)");
        Region spacer = new Region();
        HBox.setHgrow(spacer, javafx.scene.layout.Priority.ALWAYS);
        workbenchStatusIndicator =
            new global.thalion.ttio.browser.workbench.StatusIndicator();
        HBox bar = new HBox(8, statusBarLabel, spacer,
                            workbenchStatusIndicator.node());
        bar.getStyleClass().add("status-bar");
        bar.setStyle("-fx-padding: 4 8 4 8; -fx-border-color: #888;"
                   + " -fx-border-width: 1 0 0 0;");
        return bar;
    }

    // Test/integration accessors -- package-private intentionally
    BorderPane root() { return root; }
    Label statusLabel() { return statusBarLabel; }
    StackPane treeContainer() { return treeContainer; }
    StackPane detailContainer() { return detailContainer; }
    MenuItem openMenuItem() { return openItem; }
    MenuItem closeMenuItem() { return closeItem; }
    MenuItem exitMenuItem() { return exitItem; }
    MenuItem diagnosticsMenuItem() { return diagnosticsItem; }
    Stage stage() { return stage; }

    private void wireFileActions() {
        openItem.setOnAction(e -> openFileViaChooser());
        closeItem.setOnAction(e -> closeCurrentDataset());
        exitItem.setOnAction(e -> {
            closeCurrentDataset();
            javafx.application.Platform.exit();
        });
        saveAsItem.setOnAction(e -> saveAsViaChooser());
        importItem.setOnAction(e -> openImportDialog(null, null));
        exportItem.setOnAction(e -> openExportDialog());
        downloadItem.setOnAction(e -> openDownloadDialog());
        uploadItem.setOnAction(e -> openUploadDialog());
        diagnosticsItem.setOnAction(e ->
            global.thalion.ttio.browser.diag.DiagnosticsDialog.show(stage));
        workbenchConnectItem.setOnAction(e -> openLoginDialog());
        workbenchDisconnectItem.setOnAction(e -> disconnectWorkbench());
        workbenchStatusItem.setOnAction(e -> showWorkbenchStatus());
        workbenchContainersItem.setOnAction(e -> openContainerBrowser());
        workbenchUploadItem.setOnAction(e -> openWorkbenchUploadDialog());
        workbenchDownloadItem.setOnAction(e -> openWorkbenchDownloadDialog());
        workbenchTransfersItem.setOnAction(e -> openTransferQueueView());
        workbenchCohortItem.setOnAction(e -> openCohortQueryBuilder());
        workbenchPipelinesItem.setOnAction(e -> openPipelineLauncher());
        workbenchJobsItem.setOnAction(e -> openJobMonitor());
    }

    /** Open the cohort query builder window. */
    private void openCohortQueryBuilder() {
        new global.thalion.ttio.browser.workbench
            .CohortQueryBuilder(stage).show();
    }

    /** Open the pipeline launcher dialog. */
    private void openPipelineLauncher() {
        new global.thalion.ttio.browser.workbench
            .PipelineLauncher(stage).show();
    }

    /** Open the job monitor window. */
    private void openJobMonitor() {
        new global.thalion.ttio.browser.workbench
            .JobMonitor(stage).show();
    }

    /** Open the workbench container browser window. */
    private void openContainerBrowser() {
        var browser = new global.thalion.ttio.browser.workbench
            .ContainerBrowser(stage);
        browser.show();
    }

    /** Open the workbench upload dialog. */
    private void openWorkbenchUploadDialog() {
        new global.thalion.ttio.browser.workbench
            .UploadStartDialog(stage).show();
    }

    /** Open the workbench download dialog. */
    private void openWorkbenchDownloadDialog() {
        new global.thalion.ttio.browser.workbench
            .DownloadStartDialog(stage).show();
    }

    /** Open the workbench transfer queue view. */
    private void openTransferQueueView() {
        new global.thalion.ttio.browser.workbench
            .TransferQueueView(stage).show();
    }

    /** Open the workbench login dialog. */
    private void openLoginDialog() {
        var manager = global.thalion.ttio.browser.workbench.ConnectionManager.instance();
        if (manager.isConnected()) {
            var existing = manager.session();
            new Alert(Alert.AlertType.INFORMATION,
                "Already connected as " + existing.username()
                + " @ " + manager.client().host()
                + ". Disconnect first to switch accounts.",
                ButtonType.OK).showAndWait();
            return;
        }
        var dlg = new global.thalion.ttio.browser.workbench.LoginDialog(stage);
        dlg.showAndConnect(session -> {
            // No additional UI hookup yet -- W5.2+ panels listen on
            // ConnectionManager themselves. The status indicator already
            // reflects the new state via its listener.
        });
    }

    /** Disconnect from the workbench server (idempotent). */
    private void disconnectWorkbench() {
        global.thalion.ttio.browser.workbench.ConnectionManager.instance().disconnect();
    }

    /** Show a modal info dialog with the current workbench connection. */
    private void showWorkbenchStatus() {
        var manager = global.thalion.ttio.browser.workbench.ConnectionManager.instance();
        String body;
        if (!manager.isConnected()) {
            body = "Not connected.\n\nLast status: "
                + manager.state()
                + (manager.lastMessage().isEmpty()
                    ? "" : "\n" + manager.lastMessage());
        } else {
            var s = manager.session();
            var c = manager.client();
            body = String.format(
                "Endpoint: %s://%s:%d%n"
                + "User:     %s%n"
                + "Provider: %s%n"
                + "Projects: %s%n"
                + "Capabilities: %d granted%n"
                + "Session id: %s",
                c.httpScheme(), c.host(), c.port(),
                s.username(), s.provider(),
                s.projects() == null ? "(none)" : s.projects().toString(),
                s.capabilities() == null ? 0 : s.capabilities().size(),
                s.sessionId());
        }
        Alert info = new Alert(Alert.AlertType.INFORMATION, body, ButtonType.OK);
        info.setHeaderText("Workbench status");
        info.initOwner(stage);
        info.showAndWait();
    }

    /** Open the transport download wizard. */
    private void openDownloadDialog() {
        var dlg = new global.thalion.ttio.browser.transport.DownloadDialog(stage);
        dlg.showAndDownload(target -> loadDataset(target.toString(), false));
    }

    /** Open the transport upload wizard. */
    private void openUploadDialog() {
        String defaultPath = currentDataset != null ? currentDataset.path() : "";
        var dlg = new global.thalion.ttio.browser.transport.UploadDialog(stage, defaultPath);
        dlg.showAndUpload(() -> statusBarLabel.setText("Upload complete."));
    }

    /** Open the export wizard. No-op if no dataset is currently open. */
    private void openExportDialog() {
        if (currentDataset == null) {
            new javafx.scene.control.Alert(
                javafx.scene.control.Alert.AlertType.INFORMATION,
                "Open a dataset first.").showAndWait();
            return;
        }
        var dlg = new global.thalion.ttio.browser.exporters
            .ExportDialog(stage, currentDataset);
        dlg.showAndExport(out -> {
            statusBarLabel.setText("Exported to " + out);
        });
    }

    /** Open the import wizard. {@code preFormat} and {@code preSource}
     *  may be null; supplied non-null when invoked from drag-drop. */
    private void openImportDialog(String preFormat, java.nio.file.Path preSource) {
        var dlg = new global.thalion.ttio.browser.importers
            .ImportDialog(stage);
        if (preFormat != null) dlg.preSelectFormat(preFormat);
        if (preSource != null) dlg.preSelectSource(preSource);
        dlg.showAndImport(target -> loadDataset(target.toString(), false));
    }

    private void saveAsViaChooser() {
        if (currentDataset == null) return;
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Save As");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File target = chooser.showSaveDialog(stage);
        if (target == null) return;
        try {
            java.nio.file.Files.copy(
                java.nio.file.Paths.get(currentDataset.path()),
                target.toPath(),
                java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            // Switch open to the new path, read-write
            String oldPath = currentDataset.path();
            closeCurrentDataset();
            loadDataset(target.toString(), /* readOnly = */ false);
        } catch (java.io.IOException ex) {
            Alert err = new Alert(Alert.AlertType.ERROR,
                "Save As failed: " + ex.getMessage(), ButtonType.OK);
            err.showAndWait();
        }
    }

    private void openFileViaChooser() {
        if (currentDataset != null) {
            Alert confirm = new Alert(Alert.AlertType.CONFIRMATION,
                "Close currently-open " + currentDataset.path() + "?",
                ButtonType.OK, ButtonType.CANCEL);
            if (confirm.showAndWait().orElse(ButtonType.CANCEL) != ButtonType.OK) {
                return;
            }
            closeCurrentDataset();
        }
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Open .tio file");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File picked = chooser.showOpenDialog(stage);
        if (picked == null) return;
        loadDataset(picked.toString(), /* readOnly = */ true);
    }

    public void loadDataset(String path, boolean readOnly) {
        DatasetOpenTask task = new DatasetOpenTask(path, readOnly);
        statusBarLabel.setText("Opening " + path + "…");
        task.setOnSucceeded(ev -> {
            currentDataset = task.getValue();
            updateStatusBarFromDataset();
            DatasetTreeNode treeRoot = DatasetTreeBuilder.build(currentDataset);
            treeView.setRoot(treeRoot);
            detailPane.setCurrentDataset(currentDataset);
        });
        task.setOnFailed(ev -> {
            Throwable t = task.getException();
            statusBarLabel.setText("(open failed)");
            Alert err = new Alert(Alert.AlertType.ERROR,
                "Could not open " + path + ":\n\n" + t.getMessage(),
                ButtonType.OK);
            err.setHeaderText("Open failed");
            err.showAndWait();
        });
        Thread th = new Thread(task, "open-" + path);
        th.setDaemon(true);
        th.start();
    }

    private void updateStatusBarFromDataset() {
        OpenDataset d = currentDataset;
        if (d == null) { statusBarLabel.setText("(no file)"); return; }
        statusBarLabel.setText(String.format(
            "%s · v%s · MS=%d · Genomic=%d · Refs=%d %s",
            d.path(), d.formatVersion(), d.msRunCount(), d.genomicRunCount(),
            d.referenceCount(),
            d.isEncrypted() ? "· 🔒 ENCRYPTED" : "· 🔓"));
    }

    private void closeCurrentDataset() {
        if (currentDataset != null) {
            currentDataset.close();
            currentDataset = null;
        }
        if (treeView != null) treeView.clear();
        if (detailPane != null) detailPane.setCurrentDataset(null);
        updateStatusBarFromDataset();
    }

    public OpenDataset currentDataset() { return currentDataset; }

    public DatasetTreeView tree() { return treeView; }

    public DetailPane detail() { return detailPane; }

    public void dispose() {
        if (workbenchStatusIndicator != null) workbenchStatusIndicator.dispose();
        if (stage != null) stage.close();
    }
}

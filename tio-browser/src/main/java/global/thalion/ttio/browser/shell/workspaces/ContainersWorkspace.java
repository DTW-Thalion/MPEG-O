/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.importers.FormatSniffer;
import global.thalion.ttio.browser.importers.ImportDialog;
import global.thalion.ttio.browser.model.DatasetOpenTask;
import global.thalion.ttio.browser.model.DatasetTreeBuilder;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.shell.Workspace;
import global.thalion.ttio.browser.shell.containers.ContainerRoster;
import global.thalion.ttio.browser.shell.containers.UnifiedContainerNode;
import global.thalion.ttio.browser.shell.containers.UnifiedContainerTreeView;
import global.thalion.ttio.browser.util.RecentFiles;
import global.thalion.ttio.browser.view.*;
import global.thalion.ttio.browser.view.LocalRootInfoTab;
import global.thalion.ttio.browser.view.ProjectListingTab;
import global.thalion.ttio.browser.view.ServerContainerOverviewTab;
import global.thalion.ttio.browser.view.headers.*;
import global.thalion.ttio.browser.view.overview.OverviewTab;
import global.thalion.ttio.browser.view.plot.*;
import global.thalion.ttio.browser.workbench.EncodingPanel;
import global.thalion.ttio.browser.workbench.LoginDialog;
import javafx.geometry.Orientation;
import javafx.scene.control.*;
import javafx.scene.input.DragEvent;
import javafx.scene.input.Dragboard;
import javafx.scene.input.TransferMode;
import javafx.scene.layout.*;
import javafx.stage.FileChooser;
import javafx.stage.Window;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;

/**
 * Three-pane workspace for local + server containers.
 */
public final class ContainersWorkspace implements Workspace {

    // --- core layout ---
    private final SplitPane root = new SplitPane();
    private final Window owner;

    // --- left pane ---
    private final UnifiedContainerTreeView unifiedTree = new UnifiedContainerTreeView();

    // --- middle pane (dataset inner tree) ---
    private final DatasetTreeView treeView = new DatasetTreeView();
    private final Label statusLabel = new Label("(no file)");
    private final BorderPane middlePane;
    private final StackPane middleContent = new StackPane();
    private final Label middlePlaceholder = new Label(
        "Open a .tio file (File → Open) or import a foreign format\n"
        + "(File → Import) to populate the dataset tree here.");

    // --- right pane ---
    private final DetailPane detailPane = new DetailPane();
    private final LocalRootInfoTab localRootInfo = new LocalRootInfoTab();
    private final ProjectListingTab projectListing = new ProjectListingTab();
    private final ServerContainerOverviewTab serverOverview = new ServerContainerOverviewTab();
    private final StackPane rightPane = new StackPane();

    // --- state ---
    private OpenDataset current;
    private final RecentFiles recent = new RecentFiles("tio-browser", 8);

    public ContainersWorkspace(Window owner) {
        this.owner = owner;
        registerTabs();
        treeView.onSelected(detailPane::onSelection);

        middlePlaceholder.setStyle("-fx-text-fill: #888; -fx-text-alignment: center;");
        middlePlaceholder.setWrapText(true);
        middlePlaceholder.setMaxWidth(280);
        middleContent.getChildren().addAll(middlePlaceholder, treeView.control());
        showMiddlePlaceholder();
        middlePane = new BorderPane(middleContent);
        middlePane.setBottom(statusLabel);

        rightPane.getChildren().addAll(
            detailPane.control(),
            localRootInfo.node(),
            projectListing.node(),
            serverOverview.node());
        showInRight(localRootInfo.node());

        localRootInfo.onOpen(()   -> openFile(owner));
        localRootInfo.onEncode(() -> encodeAction());
        localRootInfo.onImport(() -> importAction());

        // SplitPane always carries all three items; the middle one toggles
        // between a placeholder Label and the populated DatasetTreeView
        // rather than being inserted/removed at runtime (dynamic-add to
        // SplitPane.getItems has unreliable divider geometry on JavaFX 21).
        root.setOrientation(Orientation.HORIZONTAL);
        root.getItems().addAll(unifiedTree.control(), middlePane, rightPane);
        root.setDividerPositions(0.22, 0.50);

        unifiedTree.control().getSelectionModel().selectedItemProperty()
            .addListener((obs, old, newItem) -> {
                if (newItem == null) return;
                onUnifiedSelection(newItem.getValue());
            });

        root.setOnDragOver(this::onDragOver);
        root.setOnDragDropped(this::onDragDropped);
    }

    @Override public String key()      { return "containers"; }
    @Override public String tooltip()  { return "Containers"; }
    @Override public String iconText() { return "📁"; }
    @Override public Region node()     { return root; }
    @Override public void onShow()     {}
    @Override public void onHide()     {}

    public OpenDataset currentDataset()          { return current; }
    public DatasetTreeView tree()                { return treeView; }
    public DetailPane detail()                   { return detailPane; }
    public Label statusLabel()                   { return statusLabel; }
    public UnifiedContainerTreeView unifiedTreeForTest() { return unifiedTree; }
    public java.util.List<String> recentFiles()  { return recent.recent(); }

    public void openFile(Window dialogOwner) {
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Open .tio file");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File picked = chooser.showOpenDialog(dialogOwner);
        if (picked != null) loadDataset(picked.toString(), true);
    }

    public void loadDataset(String path, boolean readOnly) {
        System.err.println("[loadDataset] called: path=" + path + " readOnly=" + readOnly);
        DatasetOpenTask task = new DatasetOpenTask(path, readOnly);
        statusLabel.setText("Opening " + path + "…");
        task.setOnSucceeded(ev -> {
            System.err.println("[loadDataset] open succeeded; building tree");
            current = task.getValue();
            statusLabel.setText(current.path());
            DatasetTreeNode treeRoot = DatasetTreeBuilder.build(current);
            treeView.setRoot(treeRoot);
            detailPane.setCurrentDataset(current);
            unifiedTree.setOpenFile(path);
            showMiddleTree();
            showInRight(detailPane.control());
            recent.record(path);
            System.err.println("[loadDataset] tree populated; middle tree visible");
        });
        task.setOnFailed(ev -> {
            Throwable t = task.getException();
            System.err.println("[loadDataset] FAILED: "
                + (t == null ? "(null exception)" : t.toString()));
            if (t != null) t.printStackTrace();
            statusLabel.setText("(open failed)");
            new Alert(Alert.AlertType.ERROR,
                "Could not open " + path + ":\n\n"
                + (t == null ? "(unknown)" : t.getMessage()),
                ButtonType.OK).showAndWait();
        });
        Thread th = new Thread(task, "open-" + path);
        th.setDaemon(true);
        th.start();
    }

    public void closeDataset() {
        if (current != null) {
            current.close();
            current = null;
        }
        treeView.clear();
        detailPane.setCurrentDataset(null);
        statusLabel.setText("(no file)");
        unifiedTree.setOpenFile(null);
        hideMiddleTree();
        showInRight(localRootInfo.node());
    }

    public void saveAs(Window dialogOwner) {
        if (current == null) return;
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Save As");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File target = chooser.showSaveDialog(dialogOwner);
        if (target == null) return;
        try {
            Files.copy(Paths.get(current.path()), target.toPath(),
                StandardCopyOption.REPLACE_EXISTING);
            closeDataset();
            loadDataset(target.toString(), false);
        } catch (java.io.IOException ex) {
            new Alert(Alert.AlertType.ERROR,
                "Save As failed: " + ex.getMessage(), ButtonType.OK).showAndWait();
        }
    }

    public void encodeAction() {
        new EncodingPanel(owner).show();
    }

    public void importAction() {
        new ImportDialog(owner).showAndImport(target -> loadDataset(target.toString(), false));
    }

    public void handleDrop(File file) {
        if (file == null) return;
        Path p = file.toPath();
        String sniffed = FormatSniffer.sniffFile(p);
        if (".tio".equals(sniffed)) {
            loadDataset(file.toString(), true);
        } else {
            new ImportDialog(owner).showAndImport(target -> loadDataset(target.toString(), false));
        }
    }

    private void onUnifiedSelection(UnifiedContainerNode node) {
        if (node == null) return;

        if (node instanceof UnifiedContainerNode.LocalRoot) {
            showInRight(localRootInfo.node());
            hideMiddleTree();

        } else if (node instanceof UnifiedContainerNode.LocalOpenFile) {
            showMiddleTree();
            showInRight(detailPane.control());
            unifiedTree.control().getSelectionModel().clearSelection();

        } else if (node instanceof UnifiedContainerNode.ServerProject p) {
            var roster = unifiedTree.cachedRoster();
            if (roster != null) {
                var list = roster.byProject().getOrDefault(
                    p.name(), java.util.List.of());
                projectListing.setContainers(
                    javafx.collections.FXCollections.observableArrayList(list));
            } else {
                projectListing.setContainers(
                    javafx.collections.FXCollections.observableArrayList());
            }
            showInRight(projectListing.node());
            hideMiddleTree();

        } else if (node instanceof UnifiedContainerNode.ServerContainer c) {
            serverOverview.update(c);
            showInRight(serverOverview.node());
            hideMiddleTree();

        } else if (node instanceof UnifiedContainerNode.OpenLocalAction) {
            openFile(owner);
            unifiedTree.control().getSelectionModel().clearSelection();

        } else if (node instanceof UnifiedContainerNode.EncodeLocalAction) {
            encodeAction();
            unifiedTree.control().getSelectionModel().clearSelection();

        } else if (node instanceof UnifiedContainerNode.ImportLocalAction) {
            importAction();
            unifiedTree.control().getSelectionModel().clearSelection();

        } else if (node instanceof UnifiedContainerNode.ServerConnectAction) {
            new LoginDialog(owner).showAndConnect(s -> {});
            unifiedTree.control().getSelectionModel().clearSelection();
        }
    }

    private void showInRight(javafx.scene.Node node) {
        for (javafx.scene.Node child : rightPane.getChildren()) {
            boolean visible = child == node;
            child.setVisible(visible);
            child.setManaged(visible);
        }
    }

    private void showMiddleTree() {
        // Swap the placeholder for the real dataset tree inside the
        // middle pane's StackPane. SplitPane geometry is unchanged.
        middlePlaceholder.setVisible(false);
        middlePlaceholder.setManaged(false);
        treeView.control().setVisible(true);
        treeView.control().setManaged(true);
    }

    private void hideMiddleTree() { showMiddlePlaceholder(); }

    private void showMiddlePlaceholder() {
        middlePlaceholder.setVisible(true);
        middlePlaceholder.setManaged(true);
        treeView.control().setVisible(false);
        treeView.control().setManaged(false);
    }

    private void onDragOver(DragEvent event) {
        Dragboard db = event.getDragboard();
        if (db.hasFiles()) {
            event.acceptTransferModes(TransferMode.COPY);
        }
        event.consume();
    }

    private void onDragDropped(DragEvent event) {
        Dragboard db = event.getDragboard();
        boolean success = false;
        if (db.hasFiles() && !db.getFiles().isEmpty()) {
            handleDrop(db.getFiles().get(0));
            success = true;
        }
        event.setDropCompleted(success);
        event.consume();
    }

    private void registerTabs() {
        detailPane.register(new OverviewTab());
        MsHeadersTable msHeaders = new MsHeadersTable();
        NmrHeadersTable nmrHeaders = new NmrHeadersTable();
        RamanHeadersTable ramanHeaders = new RamanHeadersTable();
        SpectrumPlotTab plotTab = new SpectrumPlotTab();
        ChannelHexTab channelHexTab = new ChannelHexTab();
        msHeaders.onRowSelected(spec -> { plotTab.render(spec); channelHexTab.render(spec); });
        nmrHeaders.onRowSelected(spec -> { plotTab.render(spec); channelHexTab.render(spec); });
        ramanHeaders.onRowSelected(spec -> { plotTab.render(spec); channelHexTab.render(spec); });
        detailPane.register(msHeaders);
        detailPane.register(nmrHeaders);
        detailPane.register(ramanHeaders);
        GenomicHeadersTable genomicHeaders = new GenomicHeadersTable();
        ReadInspectorTab readInspectorTab = new ReadInspectorTab();
        genomicHeaders.onRowSelected(row -> readInspectorTab.render(row.full()));
        detailPane.register(genomicHeaders);
        detailPane.register(readInspectorTab);
        detailPane.register(new ChromDistributionView());
        detailPane.register(new ReferenceTab());
        detailPane.register(plotTab);
        detailPane.register(channelHexTab);
        detailPane.register(new ChromatogramPlotTab());
        detailPane.register(new IdentificationsTab());
        detailPane.register(new QuantificationsTab());
        detailPane.register(new ProvenanceTab());
        detailPane.register(new FeatureFlagsTab());
        detailPane.register(new EncryptionTab());
    }
}
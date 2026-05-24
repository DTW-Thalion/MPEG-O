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
import global.thalion.ttio.browser.shell.containers.UnifiedContainerNode;
import global.thalion.ttio.browser.shell.containers.UnifiedContainerTreeView;
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

    // --- right pane ---
    private final DetailPane detailPane = new DetailPane();
    private final LocalRootInfoTab localRootInfo = new LocalRootInfoTab();
    private final ProjectListingTab projectListing = new ProjectListingTab();
    private final ServerContainerOverviewTab serverOverview = new ServerContainerOverviewTab();
    private final StackPane rightPane = new StackPane();

    // --- state ---
    private OpenDataset current;

    public ContainersWorkspace(Window owner) {
        this.owner = owner;
        registerTabs();
        treeView.onSelected(detailPane::onSelection);

        middlePane = new BorderPane(treeView.control());
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

        root.setOrientation(Orientation.HORIZONTAL);
        root.getItems().addAll(unifiedTree.control(), rightPane);
        root.setDividerPositions(0.30);

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

    public void openFile(Window dialogOwner) {
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Open .tio file");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File picked = chooser.showOpenDialog(dialogOwner);
        if (picked != null) loadDataset(picked.toString(), true);
    }

    public void loadDataset(String path, boolean readOnly) {
        DatasetOpenTask task = new DatasetOpenTask(path, readOnly);
        statusLabel.setText("Opening " + path + "…");
        task.setOnSucceeded(ev -> {
            current = task.getValue();
            statusLabel.setText(current.path());
            DatasetTreeNode treeRoot = DatasetTreeBuilder.build(current);
            treeView.setRoot(treeRoot);
            detailPane.setCurrentDataset(current);
            unifiedTree.setOpenFile(path);
            showMiddleTree();
            showInRight(detailPane.control());
        });
        task.setOnFailed(ev -> {
            statusLabel.setText("(open failed)");
            new Alert(Alert.AlertType.ERROR,
                "Could not open " + path + ":\n\n" + task.getException().getMessage(),
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

        } else if (node instanceof UnifiedContainerNode.ServerProject) {
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
        if (!root.getItems().contains(middlePane)) {
            root.getItems().add(1, middlePane);
            root.setDividerPositions(0.22, 0.50);
        }
    }

    private void hideMiddleTree() {
        if (root.getItems().contains(middlePane)) {
            root.getItems().remove(middlePane);
            root.setDividerPositions(0.30);
        }
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
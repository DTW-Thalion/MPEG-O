package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.model.DatasetOpenTask;
import global.thalion.ttio.browser.model.DatasetTreeBuilder;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.shell.Workspace;
import global.thalion.ttio.browser.view.*;
import global.thalion.ttio.browser.view.headers.*;
import global.thalion.ttio.browser.view.overview.OverviewTab;
import global.thalion.ttio.browser.view.plot.*;
import javafx.geometry.Orientation;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.FileChooser;
import javafx.stage.Window;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;

public final class ContainersWorkspace implements Workspace {

    private final SplitPane root = new SplitPane();
    private final DatasetTreeView treeView = new DatasetTreeView();
    private final DetailPane detailPane = new DetailPane();
    private final Label statusLabel = new Label("(no file)");
    private OpenDataset current;

    public ContainersWorkspace() {
        registerTabs();
        treeView.onSelected(detailPane::onSelection);
        BorderPane left = new BorderPane(treeView.control());
        left.setBottom(statusLabel);
        root.setOrientation(Orientation.HORIZONTAL);
        root.getItems().addAll(left, detailPane.control());
        root.setDividerPositions(0.30);
    }

    public String key()      { return "containers"; }
    public String tooltip()  { return "Containers"; }
    public String iconText() { return "📁"; }
    public Region node()     { return root; }
    public void onShow()     {}
    public void onHide()     {}

    public OpenDataset currentDataset() { return current; }
    public DatasetTreeView tree()       { return treeView; }
    public DetailPane detail()          { return detailPane; }
    public Label statusLabel()          { return statusLabel; }

    public void openFile(Window owner) {
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Open .tio file");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File picked = chooser.showOpenDialog(owner);
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
    }

    public void saveAs(Window owner) {
        if (current == null) return;
        FileChooser chooser = new FileChooser();
        chooser.setTitle("Save As");
        chooser.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File target = chooser.showSaveDialog(owner);
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

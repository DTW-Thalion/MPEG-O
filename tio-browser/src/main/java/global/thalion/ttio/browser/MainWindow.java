package global.thalion.ttio.browser;

import javafx.geometry.Orientation;
import javafx.scene.Scene;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.Stage;

public class MainWindow {

    private Stage stage;
    private BorderPane root;
    private Label statusBarLabel;
    private SplitPane mainSplit;
    private StackPane treeContainer;
    private StackPane detailContainer;

    private MenuItem openItem, closeItem, saveAsItem, exitItem;
    private MenuItem importItem, exportItem, downloadItem, uploadItem, diagnosticsItem;

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
        primaryStage.setTitle("tio-browser");
        primaryStage.show();
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

        Menu toolsMenu = new Menu("Tools");
        diagnosticsItem = new MenuItem("Diagnostics…");
        toolsMenu.getItems().add(diagnosticsItem);

        Menu helpMenu = new Menu("Help");
        helpMenu.getItems().add(new MenuItem("About"));

        return new MenuBar(fileMenu, importMenu, exportMenu, transportMenu,
                          toolsMenu, helpMenu);
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
        treeContainer = new StackPane(new Label("(no dataset open)"));
        treeContainer.setMinWidth(240);
        detailContainer = new StackPane(new Label("(open a .tio file to begin)"));
        mainSplit.getItems().addAll(treeContainer, detailContainer);
        mainSplit.setDividerPositions(0.30);
        return mainSplit;
    }

    private HBox buildStatusBar() {
        statusBarLabel = new Label("(no file)");
        HBox bar = new HBox(statusBarLabel);
        bar.getStyleClass().add("status-bar");
        bar.setStyle("-fx-padding: 4 8 4 8; -fx-border-color: #888;"
                   + " -fx-border-width: 1 0 0 0;");
        return bar;
    }

    // Test/integration accessors -- package-private intentionally
    BorderPane root() { return root; }
    Label statusBar() { return statusBarLabel; }
    StackPane treeContainer() { return treeContainer; }
    StackPane detailContainer() { return detailContainer; }
    MenuItem openMenuItem() { return openItem; }
    MenuItem closeMenuItem() { return closeItem; }
    MenuItem exitMenuItem() { return exitItem; }
    MenuItem diagnosticsMenuItem() { return diagnosticsItem; }
    Stage stage() { return stage; }

    public void dispose() {
        if (stage != null) stage.close();
    }
}

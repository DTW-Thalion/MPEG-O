/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.containers.Container;
import global.thalion.ttio.workbench.containers.ContainerListPage;
import global.thalion.ttio.workbench.containers.ContainerManifest;
import global.thalion.ttio.workbench.containers.ContainersClient;
import javafx.application.Platform;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.concurrent.Task;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.control.SplitPane;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;
import javafx.scene.control.TextArea;
import javafx.scene.control.TextField;
import javafx.beans.property.SimpleBooleanProperty;
import javafx.beans.property.SimpleStringProperty;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;

/**
 * Modal Container Browser window for the workbench remote tree.
 *
 * <p>Displays a paginated {@link TableView} of {@link Container}
 * rows from {@code GET /v1/containers}, with project / owner /
 * limit filters and a "Load more" button driving the cursor
 * pagination. Selecting a row fetches the
 * {@link ContainerManifest} and renders it in the right pane.</p>
 *
 * <p>Opens via {@code MainWindow}'s {@code Workbench -> Browse
 * containers...} menu. Requires an active workbench connection
 * (gated client-side; the user is shown an Alert if disconnected).</p>
 */
public final class ContainerBrowser {

    private final Window owner;
    private final ConnectionManager manager;

    private final Stage stage = new Stage();
    private final TextField projectField = new TextField();
    private final TextField ownerField = new TextField();
    private final TextField limitField = new TextField("50");
    private final Button refreshBtn = new Button("Refresh");
    private final Button loadMoreBtn = new Button("Load more");
    private final Label statusLabel = new Label("");
    private final TableView<Container> table = new TableView<>();
    private final TextArea detailArea = new TextArea();
    private final ObservableList<Container> rows = FXCollections.observableArrayList();

    /** Cursor for the next page. Null when there are no more pages
     *  or before the first request. */
    private String nextCursor;

    public ContainerBrowser(Window owner) {
        this(owner, ConnectionManager.instance());
    }

    /** Visible for tests; production code should use the one-arg ctor. */
    public ContainerBrowser(Window owner, ConnectionManager manager) {
        this.owner = owner;
        this.manager = manager;
        buildUi();
        wireActions();
    }

    /** Show the window (non-modal -- operator can keep it open and
     *  switch between it and MainWindow). */
    public void show() {
        if (!manager.isConnected()) {
            Alert alert = new Alert(AlertType.WARNING,
                "Connect to a workbench server first "
                + "(Workbench -> Connect...).",
                javafx.scene.control.ButtonType.OK);
            alert.initOwner(owner);
            alert.showAndWait();
            return;
        }
        stage.show();
        beginRefresh();  // initial page on open
    }

    // ---- package-private accessors for TestFX ----

    Stage stage()                          { return stage; }
    TextField projectField()                { return projectField; }
    TextField ownerField()                  { return ownerField; }
    TextField limitField()                  { return limitField; }
    Button refreshButton()                  { return refreshBtn; }
    Button loadMoreButton()                 { return loadMoreBtn; }
    Label statusLabel()                     { return statusLabel; }
    TableView<Container> table()            { return table; }
    TextArea detailArea()                   { return detailArea; }
    String nextCursor()                     { return nextCursor; }
    ObservableList<Container> rows()        { return rows; }

    // ---- static helpers (pure -- testable without FX toolkit) ----

    /** Parse a positive integer for the limit field; returns null
     *  on blank / non-numeric / negative input so the client uses
     *  the server default. */
    public static Integer parseLimit(String raw) {
        if (raw == null) return null;
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) return null;
        try {
            int n = Integer.parseInt(trimmed);
            return n > 0 ? n : null;
        } catch (NumberFormatException ex) {
            return null;
        }
    }

    /** Format a Unix-epoch-seconds timestamp as an ISO-8601 UTC
     *  string. 0 (the "missing timestamp" sentinel) renders as
     *  the empty string. */
    public static String formatTimestamp(long epochSeconds) {
        if (epochSeconds <= 0) return "";
        return DateTimeFormatter.ISO_INSTANT
            .format(Instant.ofEpochSecond(epochSeconds)
                .atOffset(ZoneOffset.UTC));
    }

    /** Render a manifest as a multi-line plain-text summary for the
     *  detail pane. Stable order for testability. */
    public static String renderManifest(ContainerManifest m) {
        StringBuilder sb = new StringBuilder();
        sb.append("URI:    ").append(m.uri()).append('\n');
        if (m.title() != null && !m.title().isEmpty()) {
            sb.append("Title:  ").append(m.title()).append('\n');
        }
        if (m.isaInvestigationId() != null && !m.isaInvestigationId().isEmpty()) {
            sb.append("ISA:    ").append(m.isaInvestigationId()).append('\n');
        }
        sb.append('\n');
        sb.append("MS runs:      ").append(m.msRuns().size()).append('\n');
        for (var r : m.msRuns()) {
            sb.append("  - ").append(r.name())
              .append(" (").append(r.spectrumClass()).append(", ")
              .append(r.spectrumCount()).append(" spectra)\n");
        }
        sb.append("NMR runs:     ").append(m.nmrRuns().size()).append('\n');
        for (var r : m.nmrRuns()) {
            sb.append("  - ").append(r.name())
              .append(" (").append(r.spectrumCount()).append(" spectra)\n");
        }
        sb.append("Genomic runs: ").append(m.genomicRuns().size()).append('\n');
        for (var r : m.genomicRuns()) {
            sb.append("  - ").append(r.name())
              .append(" (").append(r.readCount()).append(" reads, ")
              .append(r.platform()).append(")\n");
        }
        sb.append('\n');
        sb.append("Identifications: ").append(m.identificationCount()).append('\n');
        sb.append("Quantifications: ").append(m.quantificationCount()).append('\n');
        sb.append("Provenance rows: ").append(m.provenanceRecordCount()).append('\n');
        return sb.toString();
    }

    // ---- internals ----

    @SuppressWarnings("unchecked")
    private void buildUi() {
        // Container is a Java record; PropertyValueFactory's bean-style
        // getX() reflection does not work. Use callback factories that
        // delegate to the record accessors.
        TableColumn<Container, String> uriCol = new TableColumn<>("URI");
        uriCol.setCellValueFactory(cd ->
            new SimpleStringProperty(cd.getValue().uri()));
        uriCol.setPrefWidth(260);
        TableColumn<Container, String> projectCol = new TableColumn<>("Project");
        projectCol.setCellValueFactory(cd ->
            new SimpleStringProperty(cd.getValue().project()));
        projectCol.setPrefWidth(100);
        TableColumn<Container, String> ownerCol = new TableColumn<>("Owner");
        ownerCol.setCellValueFactory(cd ->
            new SimpleStringProperty(cd.getValue().owner()));
        ownerCol.setPrefWidth(100);
        TableColumn<Container, Boolean> encCol = new TableColumn<>("Encrypted");
        encCol.setCellValueFactory(cd ->
            new SimpleBooleanProperty(cd.getValue().encrypted()));
        encCol.setPrefWidth(80);
        TableColumn<Container, String> createdCol = new TableColumn<>("Created (UTC)");
        createdCol.setCellValueFactory(cd ->
            new SimpleStringProperty(formatTimestamp(cd.getValue().createdAt())));
        createdCol.setPrefWidth(180);
        TableColumn<Container, String> updatedCol = new TableColumn<>("Updated (UTC)");
        updatedCol.setCellValueFactory(cd ->
            new SimpleStringProperty(formatTimestamp(cd.getValue().updatedAt())));
        updatedCol.setPrefWidth(180);
        table.getColumns().addAll(uriCol, projectCol, ownerCol, encCol,
                                    createdCol, updatedCol);
        table.setItems(rows);

        projectField.setPromptText("project (optional)");
        ownerField.setPromptText("owner (optional)");
        limitField.setPrefColumnCount(4);

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);
        HBox filterBar = new HBox(8,
            new Label("Project:"), projectField,
            new Label("Owner:"), ownerField,
            new Label("Limit:"), limitField,
            refreshBtn, spacer, statusLabel);
        filterBar.setPadding(new Insets(8));

        detailArea.setEditable(false);
        detailArea.setPromptText(
            "Select a container to load its manifest...");
        detailArea.setStyle("-fx-font-family: monospace;");

        SplitPane split = new SplitPane(new VBox(table), detailArea);
        split.setDividerPositions(0.62);
        VBox.setVgrow(split, Priority.ALWAYS);
        VBox.setVgrow(table, Priority.ALWAYS);

        HBox bottomBar = new HBox(8, loadMoreBtn);
        bottomBar.setPadding(new Insets(8));

        VBox root = new VBox(filterBar, split, bottomBar);
        Scene scene = new Scene(root, 1100, 600);
        stage.setScene(scene);
        stage.setTitle("Workbench: browse containers");
        stage.initModality(Modality.NONE);
        if (owner != null) stage.initOwner(owner);
        loadMoreBtn.setDisable(true);
    }

    private void wireActions() {
        refreshBtn.setOnAction(e -> beginRefresh());
        loadMoreBtn.setOnAction(e -> beginLoadMore());
        table.getSelectionModel().selectedItemProperty().addListener(
            (obs, oldVal, newVal) -> {
                if (newVal != null) beginManifest(newVal);
            });
    }

    private void beginRefresh() {
        rows.clear();
        nextCursor = null;
        loadMoreBtn.setDisable(true);
        loadPage(null);
    }

    private void beginLoadMore() {
        if (nextCursor == null) return;
        loadPage(nextCursor);
    }

    private void loadPage(String cursor) {
        final String project = trimToNull(projectField.getText());
        final String ownerArg = trimToNull(ownerField.getText());
        final Integer limit = parseLimit(limitField.getText());
        setBusy(true, "Loading containers...");

        Task<ContainerListPage> task = new Task<>() {
            @Override protected ContainerListPage call() {
                ContainersClient client = manager.client().containers();
                return client.list(project, ownerArg, limit, cursor);
            }
        };
        task.setOnSucceeded(ev -> {
            ContainerListPage page = task.getValue();
            rows.addAll(page.containers());
            nextCursor = page.nextCursor();
            loadMoreBtn.setDisable(!page.hasMore());
            setBusy(false, page.hasMore()
                ? rows.size() + " loaded; more available"
                : rows.size() + " loaded (end of list)");
        });
        task.setOnFailed(ev -> {
            setBusy(false, "");
            Throwable t = task.getException();
            new Alert(AlertType.ERROR,
                t == null ? "Container list failed (unknown)"
                          : t.getMessage(),
                javafx.scene.control.ButtonType.OK).showAndWait();
        });
        Thread th = new Thread(task, "ttio-workbench-list-containers");
        th.setDaemon(true);
        th.start();
    }

    private void beginManifest(Container c) {
        detailArea.setText("Loading manifest for " + c.uri() + "...");
        Task<ContainerManifest> task = new Task<>() {
            @Override protected ContainerManifest call() {
                return manager.client().containers().manifest(c.uri());
            }
        };
        task.setOnSucceeded(ev -> {
            detailArea.setText(renderManifest(task.getValue()));
        });
        task.setOnFailed(ev -> {
            Throwable t = task.getException();
            detailArea.setText("(manifest fetch failed: "
                + (t == null ? "unknown" : t.getMessage()) + ")");
        });
        Thread th = new Thread(task, "ttio-workbench-manifest-" + c.uri());
        th.setDaemon(true);
        th.start();
    }

    private void setBusy(boolean busy, String message) {
        refreshBtn.setDisable(busy);
        loadMoreBtn.setDisable(busy || nextCursor == null);
        statusLabel.setText(message == null ? "" : message);
    }

    private static String trimToNull(String s) {
        if (s == null) return null;
        String t = s.trim();
        return t.isEmpty() ? null : t;
    }
}

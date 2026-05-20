/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.cohort.CohortPredicate;
import global.thalion.ttio.workbench.cohort.CohortQuery;
import global.thalion.ttio.workbench.cohort.CohortResult;
import javafx.application.Platform;
import javafx.beans.property.SimpleStringProperty;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.concurrent.Task;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.ChoiceBox;
import javafx.scene.control.Label;
import javafx.scene.control.SplitPane;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;
import javafx.scene.control.TextField;
import javafx.scene.control.cell.TextFieldTableCell;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.Region;
import javafx.scene.layout.VBox;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;
import javafx.util.converter.DefaultStringConverter;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Cohort query builder window. A composite-root choice (AND / OR
 * / NOT) plus a TableView of leaf rows; "Run" submits the
 * predicate as a {@link CohortQuery} via the SDK and renders the
 * result rows below.
 *
 * <p>v1.0 scope: flat list of leaves under a single composite
 * root. Nested composites are reachable via the SDK but the GUI
 * doesn't surface them (a true tree-style editor is a v1.1
 * enhancement). NOT requires exactly one leaf -- the GUI enforces
 * this client-side before submitting.</p>
 *
 * <p>The server's "phenotype rejected under OR / NOT" rule
 * (workbench-server v1.0) is enforced client-side too.</p>
 */
public final class CohortQueryBuilder {

    private static final List<String> COMPOSITES = List.of("AND", "OR", "NOT");
    private static final List<String> SELECT_VALUES = List.of(
        "containers", "subjects", "samples");

    private final Window owner;
    private final ConnectionManager manager;
    private final Stage stage = new Stage();

    private final ChoiceBox<String> compositeBox = new ChoiceBox<>();
    private final ChoiceBox<String> selectBox = new ChoiceBox<>();
    private final TableView<CohortLeafRow> leafTable = new TableView<>();
    private final ObservableList<CohortLeafRow> leafRows =
        FXCollections.observableArrayList();
    private final Button addLeafBtn = new Button("Add leaf");
    private final Button removeLeafBtn = new Button("Remove selected");
    private final Button runBtn = new Button("Run");
    private final Button previewCountBtn = new Button("Preview count");
    private final Label statusLabel = new Label("");

    private final TableView<Map<String, Object>> resultTable = new TableView<>();
    private final ObservableList<Map<String, Object>> resultRows =
        FXCollections.observableArrayList();

    public CohortQueryBuilder(Window owner) {
        this(owner, ConnectionManager.instance());
    }

    /** Visible for tests. */
    public CohortQueryBuilder(Window owner, ConnectionManager manager) {
        this.owner = owner;
        this.manager = manager;
        buildUi();
        wireActions();
    }

    public void show() {
        if (!manager.isConnected()) {
            new Alert(AlertType.WARNING,
                "Connect to a workbench server first "
                + "(Workbench -> Connect...).", ButtonType.OK).showAndWait();
            return;
        }
        if (leafRows.isEmpty()) addLeafRow();  // start with one blank row
        stage.show();
    }

    // ---- TestFX accessors ----

    Stage stage()                                { return stage; }
    ChoiceBox<String> compositeBox()              { return compositeBox; }
    ChoiceBox<String> selectBox()                 { return selectBox; }
    TableView<CohortLeafRow> leafTable()          { return leafTable; }
    ObservableList<CohortLeafRow> leafRows()      { return leafRows; }
    Button runButton()                            { return runBtn; }
    Button previewCountButton()                   { return previewCountBtn; }
    Label statusLabel()                           { return statusLabel; }
    TableView<Map<String, Object>> resultTable()  { return resultTable; }

    // ---- static helpers (pure -- testable without FX) ----

    /** Build the composite predicate for the form's current state.
     *  Throws {@link IllegalStateException} when the composite +
     *  leaf-count combination is invalid (e.g., NOT with != 1 leaf)
     *  or when phenotype appears under OR / NOT. */
    public static CohortPredicate buildPredicate(
            String composite, List<CohortLeafRow> rows) {
        if (rows.isEmpty()) {
            throw new IllegalStateException("at least one leaf required");
        }
        List<CohortPredicate> leaves = new ArrayList<>();
        for (CohortLeafRow r : rows) leaves.add(r.toPredicate());

        switch (composite) {
            case "AND":
                return leaves.size() == 1
                    ? leaves.get(0)
                    : CohortPredicate.and(leaves.toArray(CohortPredicate[]::new));
            case "OR":
                if (anyPhenotype(rows)) {
                    throw new IllegalStateException(
                        "phenotype leaves are not allowed under OR (v1.0 server rule)");
                }
                return leaves.size() == 1
                    ? leaves.get(0)
                    : CohortPredicate.or(leaves.toArray(CohortPredicate[]::new));
            case "NOT":
                if (leaves.size() != 1) {
                    throw new IllegalStateException(
                        "NOT requires exactly one leaf; got " + leaves.size());
                }
                if (anyPhenotype(rows)) {
                    throw new IllegalStateException(
                        "phenotype leaves are not allowed under NOT (v1.0 server rule)");
                }
                return CohortPredicate.not(leaves.get(0));
            default:
                throw new IllegalArgumentException(
                    "unknown composite: " + composite);
        }
    }

    private static boolean anyPhenotype(List<CohortLeafRow> rows) {
        for (CohortLeafRow r : rows) {
            if (r.kind() == CohortLeafRow.Kind.PHENOTYPE) return true;
        }
        return false;
    }

    // ---- UI ----

    private void buildUi() {
        compositeBox.setItems(FXCollections.observableArrayList(COMPOSITES));
        compositeBox.setValue("AND");
        selectBox.setItems(FXCollections.observableArrayList(SELECT_VALUES));
        selectBox.setValue("containers");

        // ---- leaf table ----
        TableColumn<CohortLeafRow, String> kindCol = new TableColumn<>("Kind");
        kindCol.setCellValueFactory(cd -> cd.getValue().kindLabelProperty());
        kindCol.setCellFactory(col -> {
            javafx.scene.control.cell.ChoiceBoxTableCell<CohortLeafRow, String> cell =
                new javafx.scene.control.cell.ChoiceBoxTableCell<>(
                    CohortLeafRow.Kind.CONTAINER.label(),
                    CohortLeafRow.Kind.SUBJECT.label(),
                    CohortLeafRow.Kind.SAMPLE.label(),
                    CohortLeafRow.Kind.PHENOTYPE.label());
            return cell;
        });
        kindCol.setPrefWidth(140);

        TableColumn<CohortLeafRow, String> fieldCol = new TableColumn<>("Field");
        fieldCol.setCellValueFactory(cd -> cd.getValue().fieldProperty());
        fieldCol.setCellFactory(TextFieldTableCell.forTableColumn(
            new DefaultStringConverter()));
        fieldCol.setPrefWidth(160);

        TableColumn<CohortLeafRow, String> opCol = new TableColumn<>("Op");
        opCol.setCellValueFactory(cd -> cd.getValue().opProperty());
        opCol.setCellFactory(col -> new javafx.scene.control.cell.ChoiceBoxTableCell<>(
            "eq", "ne", "lt", "gt", "le", "ge", "in", "like", "exists"));
        opCol.setPrefWidth(80);

        TableColumn<CohortLeafRow, String> valueCol = new TableColumn<>("Value");
        valueCol.setCellValueFactory(cd -> cd.getValue().rawValueProperty());
        valueCol.setCellFactory(TextFieldTableCell.forTableColumn(
            new DefaultStringConverter()));
        valueCol.setPrefWidth(240);

        leafTable.setEditable(true);
        leafTable.getColumns().addAll(kindCol, fieldCol, opCol, valueCol);
        leafTable.setItems(leafRows);

        HBox leafControls = new HBox(8, addLeafBtn, removeLeafBtn);
        leafControls.setPadding(new Insets(0, 8, 8, 8));

        HBox headerBar = new HBox(8,
            new Label("Composite:"), compositeBox,
            new Label("Return:"), selectBox);
        headerBar.setPadding(new Insets(8));

        HBox actionBar = new HBox(8,
            runBtn, previewCountBtn,
            spacer(), statusLabel);
        actionBar.setPadding(new Insets(8));

        // ---- result table (columns added dynamically) ----
        resultTable.setItems(resultRows);

        VBox top = new VBox(headerBar, leafTable, leafControls, actionBar);
        VBox.setVgrow(leafTable, Priority.ALWAYS);

        SplitPane split = new SplitPane(top, resultTable);
        split.setOrientation(javafx.geometry.Orientation.VERTICAL);
        split.setDividerPositions(0.42);

        Scene scene = new Scene(split, 1080, 720);
        stage.setScene(scene);
        stage.setTitle("Workbench: cohort query");
        stage.initModality(Modality.NONE);
        if (owner != null) stage.initOwner(owner);
    }

    private Region spacer() {
        Region r = new Region();
        HBox.setHgrow(r, Priority.ALWAYS);
        return r;
    }

    private void wireActions() {
        addLeafBtn.setOnAction(e -> addLeafRow());
        removeLeafBtn.setOnAction(e -> removeSelectedLeafRow());
        runBtn.setOnAction(e -> runQuery(false));
        previewCountBtn.setOnAction(e -> runQuery(true));
    }

    private void addLeafRow() {
        leafRows.add(new CohortLeafRow());
    }

    private void removeSelectedLeafRow() {
        CohortLeafRow row = leafTable.getSelectionModel().getSelectedItem();
        if (row != null) leafRows.remove(row);
    }

    private void runQuery(boolean previewOnly) {
        CohortPredicate predicate;
        try {
            predicate = buildPredicate(compositeBox.getValue(),
                new ArrayList<>(leafRows));
        } catch (RuntimeException ex) {
            showError(ex.getMessage());
            return;
        }
        CohortQuery query = CohortQuery.builder()
            .select(selectBox.getValue())
            .predicate(predicate)
            .limit(100)
            .build();

        statusLabel.setText(previewOnly ? "Counting..." : "Running...");
        runBtn.setDisable(true);
        previewCountBtn.setDisable(true);

        Task<Object> task = new Task<>() {
            @Override protected Object call() {
                if (previewOnly) {
                    return manager.client().previewCount(query);
                }
                return manager.client().query(query);
            }
        };
        task.setOnSucceeded(ev -> {
            runBtn.setDisable(false);
            previewCountBtn.setDisable(false);
            Object result = task.getValue();
            if (result instanceof Long count) {
                statusLabel.setText("Preview count: " + count);
            } else if (result instanceof CohortResult cr) {
                renderResult(cr);
                statusLabel.setText(cr.rows().size() + " rows returned"
                    + (cr.nextCursor() != null ? " (more available)" : ""));
            }
        });
        task.setOnFailed(ev -> {
            runBtn.setDisable(false);
            previewCountBtn.setDisable(false);
            statusLabel.setText("");
            Throwable t = task.getException();
            showError(t == null ? "Query failed" : t.getMessage());
        });
        Thread th = new Thread(task, "ttio-cohort-query");
        th.setDaemon(true);
        th.start();
    }

    private void renderResult(CohortResult cr) {
        resultTable.getColumns().clear();
        resultRows.clear();
        if (cr.rows().isEmpty()) return;
        // Build columns from the union of keys in the first row.
        Map<String, Object> sample = cr.rows().get(0);
        for (String key : sample.keySet()) {
            TableColumn<Map<String, Object>, String> col = new TableColumn<>(key);
            col.setCellValueFactory(cd -> new SimpleStringProperty(
                String.valueOf(cd.getValue().get(key))));
            col.setPrefWidth(120);
            resultTable.getColumns().add(col);
        }
        resultRows.addAll(cr.rows());
    }

    private void showError(String message) {
        if (Platform.isFxApplicationThread()) {
            new Alert(AlertType.ERROR, message, ButtonType.OK).showAndWait();
        } else {
            Platform.runLater(() ->
                new Alert(AlertType.ERROR, message, ButtonType.OK).showAndWait());
        }
    }
}

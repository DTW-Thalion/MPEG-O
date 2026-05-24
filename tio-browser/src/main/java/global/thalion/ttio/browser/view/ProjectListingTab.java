/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.shell.containers.UnifiedContainerNode;
import global.thalion.ttio.browser.util.Units;
import javafx.beans.property.ReadOnlyStringWrapper;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.scene.control.Button;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;
import javafx.scene.layout.BorderPane;
import javafx.scene.layout.Region;

import java.util.function.Consumer;

/**
 * Paged container table shown when the user selects a {@link UnifiedContainerNode.ServerProject}
 * in the unified container tree.
 *
 * <p>For Stage 6 v1, actual paged loading via {@code WorkbenchClient.listContainers} is
 * deferred. The table accepts an {@link ObservableList} set via
 * {@link #setContainers(ObservableList)} and renders URI/Name/Size columns.
 * The "Load more…" button at the bottom exposes a {@link Runnable} hook for
 * the future pagination implementation.</p>
 *
 * <p>Intentionally not an {@code AbstractDetailTab} — the selection model
 * for unified container tree nodes differs from the inner dataset-tree model.</p>
 */
public final class ProjectListingTab {

    private final BorderPane root = new BorderPane();
    private final TableView<UnifiedContainerNode.ServerContainer> table = new TableView<>();
    private final Button loadMoreBtn = new Button("Load more…");
    private Consumer<UnifiedContainerNode.ServerContainer> onContainerSelected = c -> {};

    public ProjectListingTab() {
        TableColumn<UnifiedContainerNode.ServerContainer, String> uriCol = new TableColumn<>("URI");
        uriCol.setCellValueFactory(c -> new ReadOnlyStringWrapper(c.getValue().uri()));
        uriCol.setPrefWidth(300);

        TableColumn<UnifiedContainerNode.ServerContainer, String> nameCol = new TableColumn<>("Name");
        nameCol.setCellValueFactory(c -> new ReadOnlyStringWrapper(c.getValue().displayName()));
        nameCol.setPrefWidth(200);

        TableColumn<UnifiedContainerNode.ServerContainer, String> sizeCol = new TableColumn<>("Size");
        sizeCol.setCellValueFactory(c -> new ReadOnlyStringWrapper(
            Units.humanBytes(c.getValue().sizeBytes())));
        sizeCol.setPrefWidth(100);

        table.getColumns().setAll(uriCol, nameCol, sizeCol);
        table.setItems(FXCollections.observableArrayList());
        table.getSelectionModel().selectedItemProperty().addListener((o, a, b) -> {
            if (b != null) onContainerSelected.accept(b);
        });

        root.setCenter(table);
        root.setBottom(loadMoreBtn);
    }

    /** Returns the root layout region for embedding in a parent container. */
    public Region node() { return root; }

    /** Exposed for unit tests only. */
    public TableView<UnifiedContainerNode.ServerContainer> tableForTest() { return table; }

    /** Exposed for unit tests only. */
    public Button loadMoreButtonForTest() { return loadMoreBtn; }

    /**
     * Replaces the table's item list with the supplied observable list.
     * Subsequent mutations to the list are reflected automatically.
     */
    public void setContainers(ObservableList<UnifiedContainerNode.ServerContainer> list) {
        table.setItems(list);
    }

    /**
     * Registers a callback invoked when the user selects a row.
     * Passing {@code null} clears the handler.
     */
    public void onContainerSelected(Consumer<UnifiedContainerNode.ServerContainer> handler) {
        this.onContainerSelected = handler == null ? c -> {} : handler;
    }

    /** Registers the action for the "Load more…" button. */
    public void onLoadMore(Runnable r) {
        loadMoreBtn.setOnAction(e -> r.run());
    }
}

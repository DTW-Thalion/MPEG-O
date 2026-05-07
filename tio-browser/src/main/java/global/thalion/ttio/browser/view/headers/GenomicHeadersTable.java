package global.thalion.ttio.browser.view.headers;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import global.thalion.ttio.browser.view.AbstractDetailTab;
import global.thalion.ttio.genomics.GenomicRun;
import javafx.beans.property.SimpleObjectProperty;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.collections.transformation.FilteredList;
import javafx.scene.Node;
import javafx.scene.control.ChoiceBox;
import javafx.scene.control.Label;
import javafx.scene.control.TableColumn;
import javafx.scene.control.TableView;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.function.Consumer;

/**
 * Headers table for genomic runs (one row per aligned read). Adds a
 * chromosome filter ChoiceBox above the table; rows iterate
 * {@link GenomicRun#index()} so the full payload doesn't need to load.
 */
public class GenomicHeadersTable implements AbstractDetailTab {

    private static final String FILTER_ALL = "(all)";
    private static final String FILTER_UNMAPPED = "* (unmapped)";

    private final TableView<GenomicRowAdapter> table = new TableView<>();
    private final ObservableList<GenomicRowAdapter> backing =
        FXCollections.observableArrayList();
    private final FilteredList<GenomicRowAdapter> filtered =
        new FilteredList<>(backing, r -> true);
    private final ChoiceBox<String> chromFilter = new ChoiceBox<>();
    private final VBox root;
    private Consumer<GenomicRowAdapter> rowSelectedListener;

    public GenomicHeadersTable() {
        table.setItems(filtered);
        table.getColumns().add(col("idx",       GenomicRowAdapter::index));
        table.getColumns().add(col("chrom",     GenomicRowAdapter::chromosome));
        table.getColumns().add(col("pos",       GenomicRowAdapter::position));
        table.getColumns().add(col("flag",      GenomicRowAdapter::flag));
        table.getColumns().add(col("MAPQ",      GenomicRowAdapter::mapq));
        table.getColumns().add(col("CIGAR",     GenomicRowAdapter::cigar));
        table.getColumns().add(col("length",    GenomicRowAdapter::length));
        table.getColumns().add(col("read_name", GenomicRowAdapter::readName));
        table.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY_FLEX_LAST_COLUMN);
        table.getSelectionModel().selectedItemProperty().addListener(
            (obs, old, sel) -> {
                if (sel != null && rowSelectedListener != null) {
                    rowSelectedListener.accept(sel);
                }
            });

        chromFilter.valueProperty().addListener((obs, old, val) -> applyFilter());

        HBox controls = new HBox(8, new Label("chromosome:"), chromFilter);
        controls.setStyle("-fx-padding: 4 8 4 8;");
        root = new VBox(controls, table);
        VBox.setVgrow(table, javafx.scene.layout.Priority.ALWAYS);
    }

    @Override public String title() { return "Genomic Headers"; }
    @Override public Node content() { return root; }

    @Override
    public boolean appliesTo(DatasetTreeNode s) {
        return s.kind() == TreeNodeKind.GENOMIC_RUN;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        GenomicRun run = d.dataset().genomicRuns().get(selection.key());
        if (run == null) {
            backing.clear();
            chromFilter.setItems(FXCollections.observableArrayList(FILTER_ALL));
            chromFilter.setValue(FILTER_ALL);
            return;
        }
        int n = run.readCount();
        java.util.List<GenomicRowAdapter> rows = new java.util.ArrayList<>(n);
        Set<String> chroms = new LinkedHashSet<>();
        boolean hasUnmapped = false;
        for (int i = 0; i < n; i++) {
            rows.add(new GenomicRowAdapter(run, i));
            String c = run.index().chromosomeAt(i);
            if (c == null || c.isEmpty() || c.equals("*")) {
                hasUnmapped = true;
            } else {
                chroms.add(c);
            }
        }
        backing.setAll(rows);

        java.util.List<String> filterOpts = new java.util.ArrayList<>();
        filterOpts.add(FILTER_ALL);
        filterOpts.addAll(chroms);
        if (hasUnmapped) filterOpts.add(FILTER_UNMAPPED);
        chromFilter.setItems(FXCollections.observableArrayList(filterOpts));
        chromFilter.setValue(FILTER_ALL);
    }

    public TableView<GenomicRowAdapter> table() { return table; }
    public ChoiceBox<String> chromFilter() { return chromFilter; }

    public void onRowSelected(Consumer<GenomicRowAdapter> l) {
        this.rowSelectedListener = l;
    }

    private void applyFilter() {
        String sel = chromFilter.getValue();
        if (sel == null || FILTER_ALL.equals(sel)) {
            filtered.setPredicate(r -> true);
        } else if (FILTER_UNMAPPED.equals(sel)) {
            filtered.setPredicate(r -> {
                String c = r.chromosome();
                return c == null || c.isEmpty() || c.equals("*");
            });
        } else {
            filtered.setPredicate(r -> sel.equals(r.chromosome()));
        }
    }

    private static <T> TableColumn<GenomicRowAdapter, T> col(
            String header, java.util.function.Function<GenomicRowAdapter, T> getter) {
        TableColumn<GenomicRowAdapter, T> c = new TableColumn<>(header);
        c.setCellValueFactory(cd -> new SimpleObjectProperty<>(getter.apply(cd.getValue())));
        c.setSortable(true);
        return c;
    }
}

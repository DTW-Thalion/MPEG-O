package global.thalion.ttio.browser.exporters;

import java.awt.Desktop;
import java.io.File;
import java.nio.file.Path;
import java.util.function.Consumer;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.diag.Diagnostics;
import global.thalion.ttio.browser.exporters.ExportFormatSpec.ExtraField;
import global.thalion.ttio.browser.model.OpenDataset;
import javafx.beans.value.ChangeListener;
import javafx.collections.FXCollections;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.CheckBox;
import javafx.scene.control.ChoiceBox;
import javafx.scene.control.Label;
import javafx.scene.control.ListView;
import javafx.scene.control.ProgressBar;
import javafx.scene.control.Spinner;
import javafx.scene.control.SpinnerValueFactory;
import javafx.scene.control.TextField;
import javafx.scene.control.Tooltip;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;
import javafx.stage.FileChooser;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

/**
 * File → Export wizard. Single-form layout with a left-side
 * {@link ListView} of format rows (ineligible rows greyed) and a
 * right-side extras pane that swaps controls per
 * {@link ExportFormatSpec#extras}.
 *
 * <p>Lifecycle: construct with the open dataset, call
 * {@link #showAndExport} with a callback that fires when the export
 * task finishes successfully (the callback receives the target path
 * so {@code MainWindow} can offer "Open folder").</p>
 */
public final class ExportDialog {

    private final Window owner;
    private final OpenDataset openDataset;
    private final Stage stage = new Stage();

    private final ListView<ExportFormatSpec> formatList = new ListView<>();
    private final TextField targetField = new TextField();
    private final Button targetBrowse = new Button("Browse…");

    // Extras controls
    private final ChoiceBox<String> mzTabDialect = new ChoiceBox<>();
    private final ChoiceBox<String> imzMlMode = new ChoiceBox<>();
    private final ChoiceBox<String> jcampEncoding = new ChoiceBox<>();
    private final CheckBox bamSamCheckbox = new CheckBox("Text output (SAM)");
    private final TextField bamRefField = new TextField();
    private final Button bamRefBrowse = new Button("Browse…");
    private final TextField cramRefField = new TextField();
    private final Button cramRefBrowse = new Button("Browse…");
    private final Spinner<Integer> fastaLineWidth = new Spinner<>(1, 1024, 60);
    private final CheckBox gzipCheckbox = new CheckBox("gzip output");
    private final ChoiceBox<String> fastqPhred = new ChoiceBox<>();
    private final Label jcampWarning = new Label(
        "Compressed encodings (PAC/SQZ/DIF) require equispaced X axis; " +
        "writer falls back to AFFN if not.");
    private final Label fastqWarning = new Label(
        "When source qualities are 0xFF sentinels, FASTQ emits '!' (Phred 0).");
    private final Label extrasHeader = new Label("Format options");

    private final Label eligibilityNote = new Label("");
    private final ProgressBar progress = new ProgressBar(0.0);
    private final Label statusLabel = new Label("");
    private final Button exportBtn = new Button("Export");
    private final Button cancelBtn = new Button("Cancel");

    private Consumer<Path> onExported;

    /** Refreshes the format list cell rendering when Diagnostics re-probes. */
    private final Runnable diagnosticsRefresh = () ->
        javafx.application.Platform.runLater(() -> {
            var sel = formatList.getSelectionModel().getSelectedItem();
            formatList.setItems(FXCollections.observableArrayList(
                ExportFormatRegistry.all()));
            if (sel != null) formatList.getSelectionModel().select(sel);
        });

    public ExportDialog(Window owner, OpenDataset openDataset) {
        this.owner = owner;
        this.openDataset = openDataset;
        buildUi();
        wireFormatChangeListener();
        Diagnostics.addCacheRefreshListener(diagnosticsRefresh);
        stage.setOnHidden(e ->
            Diagnostics.removeCacheRefreshListener(diagnosticsRefresh));
    }

    public void showAndExport(Consumer<Path> onExported) {
        this.onExported = onExported;
        stage.show();
    }

    /** Visible for tests. */
    Stage stage() { return stage; }
    ListView<ExportFormatSpec> formatList() { return formatList; }
    TextField targetField() { return targetField; }
    Button exportButton() { return exportBtn; }

    private void buildUi() {
        formatList.setItems(FXCollections.observableArrayList(
            ExportFormatRegistry.all()));
        formatList.setCellFactory(lv ->
            new javafx.scene.control.ListCell<>() {
                @Override
                protected void updateItem(ExportFormatSpec spec, boolean empty) {
                    super.updateItem(spec, empty);
                    if (empty || spec == null) {
                        setText(null);
                        setTooltip(null);
                        setDisable(false);
                        return;
                    }
                    setText(spec.name);
                    boolean eligible =
                        ExportEligibility.check(spec, openDataset);
                    boolean onClasspath = spec.writerOnClasspath();
                    boolean binaryOk = spec.binaryAvailable();
                    String tooltip =
                        ExportEligibility.tooltipReason(spec, openDataset);
                    if (!onClasspath) {
                        setText(spec.name + "  (writer missing)");
                        tooltip = "Writer class not on classpath: "
                            + spec.writerClassFqn;
                    } else if (!binaryOk) {
                        setText(spec.name + "  (unavailable)");
                        tooltip = "Requires `" + spec.requiredBinary
                            + "` on PATH";
                    }
                    setTooltip(new Tooltip(tooltip));
                    setDisable(!(eligible && onClasspath && binaryOk));
                }
            });

        mzTabDialect.getItems().setAll("1.0", "2.0.0-M");
        mzTabDialect.getSelectionModel().selectFirst();

        imzMlMode.getItems().setAll("continuous", "processed");
        imzMlMode.getSelectionModel().selectFirst();

        jcampEncoding.getItems().setAll("AFFN", "PAC", "SQZ", "DIF");
        jcampEncoding.getSelectionModel().selectFirst();

        fastaLineWidth.setValueFactory(
            new SpinnerValueFactory.IntegerSpinnerValueFactory(1, 1024, 60));

        fastqPhred.getItems().setAll("Phred+33", "Phred+64");
        fastqPhred.getSelectionModel().selectFirst();

        GridPane extras = new GridPane();
        extras.setHgap(8);
        extras.setVgap(6);
        extras.setPadding(new Insets(8));
        int row = 0;
        extras.add(new Label("mzTab dialect:"),  0, row);
        extras.add(mzTabDialect,                  1, row, 2, 1);
        row++;
        extras.add(new Label("imzML mode:"),     0, row);
        extras.add(imzMlMode,                     1, row, 2, 1);
        row++;
        extras.add(new Label("JCAMP encoding:"), 0, row);
        extras.add(jcampEncoding,                 1, row, 2, 1);
        row++;
        extras.add(jcampWarning,                  0, row, 3, 1);
        row++;
        extras.add(new Label("BAM:"),            0, row);
        extras.add(bamSamCheckbox,                1, row, 2, 1);
        row++;
        extras.add(new Label("BAM reference:"),  0, row);
        extras.add(bamRefField,                   1, row);
        extras.add(bamRefBrowse,                  2, row);
        row++;
        extras.add(new Label("CRAM reference:"), 0, row);
        extras.add(cramRefField,                  1, row);
        extras.add(cramRefBrowse,                 2, row);
        row++;
        extras.add(new Label("FASTA line width:"), 0, row);
        extras.add(fastaLineWidth,                 1, row, 2, 1);
        row++;
        extras.add(new Label(""),                0, row);
        extras.add(gzipCheckbox,                  1, row, 2, 1);
        row++;
        extras.add(new Label("FASTQ Phred:"),    0, row);
        extras.add(fastqPhred,                    1, row, 2, 1);
        row++;
        extras.add(fastqWarning,                  0, row, 3, 1);

        targetBrowse.setOnAction(e -> chooseTarget());
        bamRefBrowse.setOnAction(e -> chooseInto(bamRefField, "BAM reference FASTA"));
        cramRefBrowse.setOnAction(e -> chooseInto(cramRefField, "CRAM reference FASTA"));
        exportBtn.setOnAction(e -> runExport());
        cancelBtn.setOnAction(e -> stage.close());

        VBox left = new VBox(6, new Label("Format:"), formatList,
            new HBox(8, new Label("Target:"), targetField, targetBrowse));
        left.setPadding(new Insets(12));

        VBox right = new VBox(6, extrasHeader, extras);
        right.setPadding(new Insets(12));

        HBox split = new HBox(8, left, right);
        VBox footer = new VBox(4, eligibilityNote, progress, statusLabel,
            new HBox(8, exportBtn, cancelBtn));
        footer.setPadding(new Insets(12));
        progress.setMaxWidth(Double.MAX_VALUE);

        VBox root = new VBox(8, split, footer);

        stage.setTitle("Export dataset");
        stage.initOwner(owner);
        stage.initModality(Modality.WINDOW_MODAL);
        stage.setScene(new Scene(root, 900, 560));
    }

    private void wireFormatChangeListener() {
        ChangeListener<ExportFormatSpec> listener = (obs, old, sel) -> {
            if (sel == null) {
                eligibilityNote.setText("");
                return;
            }
            eligibilityNote.setText(
                ExportEligibility.tooltipReason(sel, openDataset));
            ExtraField extras = sel.extras;
            mzTabDialect.setDisable(extras != ExtraField.MZTAB_DIALECT);
            imzMlMode.setDisable(extras != ExtraField.IMZML_MODE);
            jcampEncoding.setDisable(extras != ExtraField.JCAMP_ENCODING);
            jcampWarning.setVisible(extras == ExtraField.JCAMP_ENCODING);
            bamSamCheckbox.setDisable(extras != ExtraField.BAM_OUTPUT);
            bamRefField.setDisable(extras != ExtraField.BAM_OUTPUT);
            bamRefBrowse.setDisable(extras != ExtraField.BAM_OUTPUT);
            cramRefField.setDisable(extras != ExtraField.CRAM_REFERENCE);
            cramRefBrowse.setDisable(extras != ExtraField.CRAM_REFERENCE);
            fastaLineWidth.setDisable(extras != ExtraField.FASTA_LINE_WIDTH);
            fastqPhred.setDisable(extras != ExtraField.FASTQ_PHRED);
            fastqWarning.setVisible(extras == ExtraField.FASTQ_PHRED);
            // gzip checkbox is shared by FASTA/FASTQ rows
            gzipCheckbox.setDisable(
                extras != ExtraField.FASTA_LINE_WIDTH
                && extras != ExtraField.FASTQ_PHRED);
            // Pre-select target extension on format change
            if (!sel.fileExts.isEmpty() && targetField.getText().isBlank()) {
                // No-op on text — extension hint applied via FileChooser
            }
        };
        formatList.getSelectionModel().selectedItemProperty().addListener(listener);
        formatList.getSelectionModel().selectFirst();
    }

    private void chooseTarget() {
        ExportFormatSpec sel = formatList.getSelectionModel().getSelectedItem();
        FileChooser fc = new FileChooser();
        if (sel != null && !sel.fileExts.isEmpty()) {
            fc.getExtensionFilters().add(
                new FileChooser.ExtensionFilter(sel.name,
                    sel.fileExts.stream().map(e -> "*" + e).toList()));
        }
        File picked = fc.showSaveDialog(stage);
        if (picked != null) targetField.setText(picked.toString());
    }

    private void chooseInto(TextField field, String desc) {
        FileChooser fc = new FileChooser();
        fc.setTitle("Select " + desc);
        File picked = fc.showOpenDialog(stage);
        if (picked != null) field.setText(picked.toString());
    }

    private void runExport() {
        ExportFormatSpec spec = formatList.getSelectionModel().getSelectedItem();
        if (spec == null) { showError("Pick a format."); return; }
        if (targetField.getText().isBlank()) {
            showError("Target path required.");
            return;
        }
        Path bamRef = bamRefField.getText().isBlank()
            ? null : Path.of(bamRefField.getText());
        Path cramRef = cramRefField.getText().isBlank()
            ? null : Path.of(cramRefField.getText());
        int phred = "Phred+64".equals(fastqPhred.getValue()) ? 64 : 33;
        Boolean gz = gzipCheckbox.isDisabled() ? null : gzipCheckbox.isSelected();

        ExportConfig cfg = new ExportConfig(
            Path.of(targetField.getText()),
            mzTabDialect.getValue(),
            imzMlMode.getValue(),
            jcampEncoding.getValue(),
            bamSamCheckbox.isSelected(),
            bamRef,
            cramRef,
            fastaLineWidth.getValue(),
            gz,
            phred,
            null);

        SpectralDataset ds = openDataset.dataset();
        ExportTask task = new ExportTask(spec, cfg, ds);
        progress.progressProperty().bind(task.progressProperty());
        statusLabel.textProperty().bind(task.messageProperty());
        exportBtn.setDisable(true);
        task.setOnSucceeded(ev -> {
            progress.progressProperty().unbind();
            statusLabel.textProperty().unbind();
            progress.setProgress(1.0);
            statusLabel.setText("Exported to " + cfg.targetPath);
            stage.close();
            if (onExported != null) onExported.accept(cfg.targetPath);
            tryOpenContainingFolder(cfg.targetPath);
        });
        task.setOnFailed(ev -> {
            progress.progressProperty().unbind();
            statusLabel.textProperty().unbind();
            exportBtn.setDisable(false);
            Throwable err = task.getException();
            showError("Export failed: "
                + (err == null ? "(unknown)" : err.getMessage()));
        });
        new Thread(task, "tio-export").start();
    }

    private void tryOpenContainingFolder(Path target) {
        if (!Desktop.isDesktopSupported()) return;
        try {
            Desktop.getDesktop().open(target.getParent().toFile());
        } catch (Exception ignored) {
            // Best-effort; on headless Linux Desktop.open() may fail.
        }
    }

    private void showError(String msg) {
        Alert a = new Alert(AlertType.ERROR, msg);
        a.initOwner(stage);
        a.showAndWait();
    }
}

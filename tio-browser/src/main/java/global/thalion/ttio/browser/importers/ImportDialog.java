package global.thalion.ttio.browser.importers;

import java.io.File;
import java.nio.file.Path;
import java.util.function.Consumer;

import global.thalion.ttio.browser.importers.ImportFormatSpec.ExtraField;
import global.thalion.ttio.browser.importers.ImportFormatSpec.SourceKind;
import javafx.beans.value.ChangeListener;
import javafx.geometry.Insets;
import javafx.scene.Scene;
import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.Button;
import javafx.scene.control.ChoiceBox;
import javafx.scene.control.ComboBox;
import javafx.scene.control.Label;
import javafx.scene.control.ProgressBar;
import javafx.scene.control.RadioButton;
import javafx.scene.control.TextField;
import javafx.scene.control.ToggleGroup;
import javafx.scene.control.Tooltip;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.VBox;
import javafx.stage.DirectoryChooser;
import javafx.stage.FileChooser;
import javafx.stage.Modality;
import javafx.stage.Stage;
import javafx.stage.Window;

/**
 * Single-form import wizard. The plan calls for a multi-step Stage; we
 * use a single GridPane that surfaces all relevant fields and shows /
 * hides per-format extras. Simpler and meets the acceptance gate.
 *
 * <p>Lifecycle: construct, optionally call {@link #preSelectFormat} and
 * {@link #preSelectSource} from drag-drop pre-population, then
 * {@link #showAndImport} to display the modal and (on success) invoke
 * the {@code onImported} callback with the resulting {@code .tio}
 * path so {@code MainWindow} can open it.</p>
 */
public final class ImportDialog {

    private final Window owner;
    private final Stage stage = new Stage();

    private final ComboBox<ImportFormatSpec> formatBox = new ComboBox<>();
    private final TextField sourceField = new TextField();
    private final Button sourceBrowse = new Button("Browse…");
    private final TextField targetField = new TextField();
    private final Button targetBrowse = new Button("Browse…");
    private final TextField runNameField = new TextField();
    private final TextField titleField = new TextField();

    private final ToggleGroup fastaModeGroup = new ToggleGroup();
    private final RadioButton fastaReference = new RadioButton("Reference");
    private final RadioButton fastaUnaligned = new RadioButton("Unaligned reads");

    private final ChoiceBox<String> fastqPhredBox = new ChoiceBox<>();

    private final TextField cramRefField = new TextField();
    private final Button cramRefBrowse = new Button("Browse…");

    private final TextField bamRefField = new TextField();
    private final Button bamRefBrowse = new Button("Browse…");

    private final Label mzTabDialect = new Label("(detected on import)");

    private final ProgressBar progress = new ProgressBar(0.0);
    private final Label statusLabel = new Label("");
    private final Button importBtn = new Button("Import");
    private final Button cancelBtn = new Button("Cancel");

    private Consumer<Path> onImported;

    public ImportDialog(Window owner) {
        this.owner = owner;
        buildUi();
        wireFormatChangeListener();
    }

    /** Pre-fill format by name (from drag-drop sniff). No-op if unknown. */
    public void preSelectFormat(String formatName) {
        if (formatName == null) return;
        for (ImportFormatSpec s : ImportFormatRegistry.all()) {
            if (s.name.equals(formatName)) {
                formatBox.getSelectionModel().select(s);
                return;
            }
        }
    }

    /** Pre-fill source path (from drag-drop). */
    public void preSelectSource(Path path) {
        if (path != null) sourceField.setText(path.toString());
    }

    public void showAndImport(Consumer<Path> onImported) {
        this.onImported = onImported;
        stage.show();
    }

    /** Visible for tests. */
    Stage stage() { return stage; }
    ComboBox<ImportFormatSpec> formatBox() { return formatBox; }
    TextField sourceField() { return sourceField; }
    TextField targetField() { return targetField; }
    Button importButton() { return importBtn; }

    private void buildUi() {
        formatBox.getItems().setAll(ImportFormatRegistry.all());
        formatBox.setCellFactory(lv ->
            new javafx.scene.control.ListCell<>() {
                @Override
                protected void updateItem(ImportFormatSpec spec, boolean empty) {
                    super.updateItem(spec, empty);
                    if (empty || spec == null) {
                        setText(null);
                        setTooltip(null);
                        setDisable(false);
                    } else {
                        setText(spec.name);
                        setTooltip(new Tooltip(spec.description));
                        if (!spec.readerOnClasspath()) {
                            setDisable(true);
                            setText(spec.name + "  (missing: "
                                + spec.readerClassFqn + ")");
                        }
                    }
                }
            });

        fastaReference.setToggleGroup(fastaModeGroup);
        fastaUnaligned.setToggleGroup(fastaModeGroup);
        fastaReference.setSelected(true);
        fastqPhredBox.getItems().setAll(
            "Auto-detect", "Phred+33", "Phred+64");
        fastqPhredBox.getSelectionModel().selectFirst();

        runNameField.setText("run_0001");
        titleField.setText("Imported");

        GridPane grid = new GridPane();
        grid.setHgap(8);
        grid.setVgap(6);
        grid.setPadding(new Insets(12));

        int row = 0;
        grid.add(new Label("Format:"),       0, row);
        grid.add(formatBox,                  1, row, 2, 1);
        row++;
        grid.add(new Label("Source:"),       0, row);
        grid.add(sourceField,                1, row);
        grid.add(sourceBrowse,               2, row);
        row++;
        grid.add(new Label("Target .tio:"),  0, row);
        grid.add(targetField,                1, row);
        grid.add(targetBrowse,               2, row);
        row++;
        grid.add(new Label("Run name:"),     0, row);
        grid.add(runNameField,               1, row, 2, 1);
        row++;
        grid.add(new Label("Title:"),        0, row);
        grid.add(titleField,                 1, row, 2, 1);
        row++;
        grid.add(new Label("FASTA mode:"),   0, row);
        HBox fastaBox = new HBox(8, fastaReference, fastaUnaligned);
        grid.add(fastaBox,                   1, row, 2, 1);
        row++;
        grid.add(new Label("FASTQ Phred:"),  0, row);
        grid.add(fastqPhredBox,              1, row, 2, 1);
        row++;
        grid.add(new Label("CRAM reference:"), 0, row);
        grid.add(cramRefField,               1, row);
        grid.add(cramRefBrowse,              2, row);
        row++;
        grid.add(new Label("BAM reference:"), 0, row);
        grid.add(bamRefField,                1, row);
        grid.add(bamRefBrowse,               2, row);
        row++;
        grid.add(new Label("mzTab dialect:"), 0, row);
        grid.add(mzTabDialect,               1, row, 2, 1);
        row++;
        grid.add(progress,                   0, row, 3, 1);
        progress.setMaxWidth(Double.MAX_VALUE);
        row++;
        grid.add(statusLabel,                0, row, 3, 1);

        sourceBrowse.setOnAction(e -> chooseSource());
        targetBrowse.setOnAction(e -> chooseTarget());
        cramRefBrowse.setOnAction(e -> chooseInto(cramRefField, "FASTA reference"));
        bamRefBrowse.setOnAction(e -> chooseInto(bamRefField, "FASTA reference"));
        importBtn.setOnAction(e -> runImport());
        cancelBtn.setOnAction(e -> stage.close());

        HBox buttons = new HBox(8, importBtn, cancelBtn);
        VBox root = new VBox(8, grid, buttons);
        root.setPadding(new Insets(8));

        stage.setTitle("Import dataset");
        stage.initOwner(owner);
        stage.initModality(Modality.WINDOW_MODAL);
        stage.setScene(new Scene(root, 600, 480));
    }

    private void wireFormatChangeListener() {
        ChangeListener<ImportFormatSpec> listener = (obs, old, sel) -> {
            if (sel == null) return;
            boolean isFasta = sel.extras == ExtraField.FASTA_TREAT_AS;
            boolean isFastq = sel.extras == ExtraField.FASTQ_PHRED;
            boolean isCram  = sel.extras == ExtraField.CRAM_REFERENCE;
            boolean isBam   = sel.extras == ExtraField.BAM_REFERENCE;
            boolean isMzTab = sel.extras == ExtraField.MZTAB_DIALECT_DETECT;
            fastaReference.setDisable(!isFasta);
            fastaUnaligned.setDisable(!isFasta);
            fastqPhredBox.setDisable(!isFastq);
            cramRefField.setDisable(!isCram);
            cramRefBrowse.setDisable(!isCram);
            bamRefField.setDisable(!isBam);
            bamRefBrowse.setDisable(!isBam);
            mzTabDialect.setDisable(!isMzTab);
        };
        formatBox.getSelectionModel().selectedItemProperty().addListener(listener);
        formatBox.getSelectionModel().selectFirst();
    }

    private void chooseSource() {
        ImportFormatSpec spec = formatBox.getSelectionModel().getSelectedItem();
        if (spec == null) return;
        File picked;
        if (spec.sourceKind == SourceKind.DIRECTORY) {
            DirectoryChooser dc = new DirectoryChooser();
            picked = dc.showDialog(stage);
        } else {
            FileChooser fc = new FileChooser();
            picked = fc.showOpenDialog(stage);
        }
        if (picked != null) sourceField.setText(picked.toString());
    }

    private void chooseTarget() {
        FileChooser fc = new FileChooser();
        fc.getExtensionFilters().add(
            new FileChooser.ExtensionFilter("TTI-O dataset", "*.tio"));
        File picked = fc.showSaveDialog(stage);
        if (picked != null) targetField.setText(picked.toString());
    }

    private void chooseInto(TextField field, String desc) {
        FileChooser fc = new FileChooser();
        fc.setTitle("Select " + desc);
        File picked = fc.showOpenDialog(stage);
        if (picked != null) field.setText(picked.toString());
    }

    private void runImport() {
        ImportFormatSpec spec = formatBox.getSelectionModel().getSelectedItem();
        if (spec == null) { showError("Pick a format."); return; }
        if (sourceField.getText().isBlank()) { showError("Source path required."); return; }
        if (targetField.getText().isBlank()) { showError("Target .tio path required."); return; }

        ImportConfig.FastaTreatAs fastaMode = fastaReference.isSelected()
            ? ImportConfig.FastaTreatAs.REFERENCE
            : ImportConfig.FastaTreatAs.UNALIGNED_READS;
        Integer phred = switch (fastqPhredBox.getSelectionModel().getSelectedIndex()) {
            case 1 -> 33;
            case 2 -> 64;
            default -> null;
        };
        Path cramRef = cramRefField.getText().isBlank()
            ? null : Path.of(cramRefField.getText());
        Path bamRef = bamRefField.getText().isBlank()
            ? null : Path.of(bamRefField.getText());

        ImportConfig cfg = new ImportConfig(
            Path.of(sourceField.getText()),
            Path.of(targetField.getText()),
            "hdf5",
            runNameField.getText(),
            titleField.getText(),
            fastaMode,
            phred,
            bamRef,
            cramRef);

        ImportTask task = new ImportTask(spec, cfg);
        progress.progressProperty().bind(task.progressProperty());
        statusLabel.textProperty().bind(task.messageProperty());
        importBtn.setDisable(true);
        task.setOnSucceeded(ev -> {
            progress.progressProperty().unbind();
            statusLabel.textProperty().unbind();
            progress.setProgress(1.0);
            stage.close();
            if (onImported != null) onImported.accept(cfg.targetTio);
        });
        task.setOnFailed(ev -> {
            progress.progressProperty().unbind();
            statusLabel.textProperty().unbind();
            importBtn.setDisable(false);
            Throwable err = task.getException();
            showError("Import failed: "
                + (err == null ? "(unknown)" : err.getMessage()));
        });
        new Thread(task, "tio-import").start();
    }

    private void showError(String msg) {
        Alert a = new Alert(AlertType.ERROR, msg);
        a.initOwner(stage);
        a.showAndWait();
    }
}

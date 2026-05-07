package global.thalion.ttio.browser.view;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import javafx.geometry.Insets;
import javafx.scene.Node;
import javafx.scene.control.Alert;
import javafx.scene.control.Button;
import javafx.scene.control.ButtonType;
import javafx.scene.control.Label;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.VBox;
import javafx.stage.FileChooser;

import java.nio.file.Files;
import java.nio.file.Path;

public class EncryptionTab implements AbstractDetailTab {

    private final VBox root = new VBox(8);
    private final GridPane grid = new GridPane();
    private final Button decryptButton = new Button("Decrypt with key…");
    private final Label statusToast = new Label();
    private OpenDataset current;

    public EncryptionTab() {
        root.setPadding(new Insets(16));
        grid.setHgap(12);
        grid.setVgap(6);
        root.getChildren().addAll(new Label("Encryption status"), grid,
            decryptButton, statusToast);
        decryptButton.setOnAction(e -> chooseKeyFileAndDecrypt());
    }

    @Override public String title() { return "Encryption"; }
    @Override public Node content() { return root; }

    @Override
    public boolean appliesTo(DatasetTreeNode selection) {
        return selection.kind() == TreeNodeKind.ENCRYPTION;
    }

    @Override
    public void update(OpenDataset d, DatasetTreeNode selection) {
        this.current = d;
        rebuildGrid();
        decryptButton.setDisable(!d.isEncrypted());
        statusToast.setText("");
    }

    private void rebuildGrid() {
        grid.getChildren().clear();
        boolean enc = current.isEncrypted();
        addRow(0, "Encrypted:",       enc ? "yes" : "no");
        addRow(1, "Algorithm:",       enc ? current.encryptionAlgorithm() : "—");
        addRow(2, "Format version:",  "v" + current.formatVersion());
        addRow(3, "Banner level:",    bannerLevel(current.formatVersion()));
        addRow(4, "Headers encrypted:",
            current.dataset().featureFlags().has("opt_encrypted_au_headers")
                ? "yes (per-AU)" : "no");
    }

    private void addRow(int r, String k, String v) {
        Label key = new Label(k);
        key.setStyle("-fx-font-weight: bold;");
        grid.add(key, 0, r);
        grid.add(new Label(v), 1, r);
    }

    private static String bannerLevel(String formatVersion) {
        if (formatVersion == null || formatVersion.isEmpty()) return "—";
        return formatVersion.startsWith("0.") ? "per-channel" : "per-AU";
    }

    private void chooseKeyFileAndDecrypt() {
        FileChooser ch = new FileChooser();
        ch.setTitle("Choose binary key file");
        java.io.File f = ch.showOpenDialog(decryptButton.getScene().getWindow());
        if (f == null) return;
        try {
            decryptFromFile(f.toPath());
            statusToast.setText("Decrypted.");
        } catch (Exception ex) {
            Alert err = new Alert(Alert.AlertType.ERROR,
                "Decryption failed: " + ex.getMessage(), ButtonType.OK);
            err.setHeaderText("Decrypt failed");
            err.showAndWait();
        }
    }

    /**
     * Read a binary key file, close the current open dataset, and invoke
     * {@link SpectralDataset#decryptInPlace(String, byte[])} to strip
     * encryption from the file at {@link OpenDataset#path()}.
     *
     * <p>The dataset reference held by the tab is invalid after this call —
     * MainWindow must reload via {@code loadDataset(path, readOnly)} to refresh
     * tree + tab state. Verifiable by re-opening the path and asserting
     * {@link SpectralDataset#isEncrypted()} is {@code false}.
     */
    public void decryptFromFile(Path keyFile) throws Exception {
        byte[] key = Files.readAllBytes(keyFile);
        String path = current.path();
        current.close();
        SpectralDataset.decryptInPlace(path, key);
    }
}

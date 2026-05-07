package global.thalion.ttio.browser.view;

import global.thalion.ttio.Enums;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import global.thalion.ttio.browser.model.TreeNodeKind;
import javafx.application.Platform;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.security.SecureRandom;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class EncryptionTabTest {

    @BeforeAll
    static void initToolkit() throws InterruptedException {
        CountDownLatch latch = new CountDownLatch(1);
        try {
            Platform.startup(latch::countDown);
        } catch (IllegalStateException e) {
            latch.countDown();
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS), "JavaFX toolkit did not start");
    }

    @Test
    void appliesOnlyToEncryptionNode() {
        EncryptionTab t = new EncryptionTab();
        assertTrue(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.ENCRYPTION, "encryption", null)));
        assertFalse(t.appliesTo(new DatasetTreeNode(
            TreeNodeKind.DATASET_ROOT, "root", null)));
    }

    @Test
    void decryptWithKeyFileSucceeds(@TempDir Path tmp) throws Exception {
        Path tio = tmp.resolve("e.tio");
        byte[] key = new byte[32];
        new SecureRandom().nextBytes(key);

        SpectralDataset ds = SpectralDataset.create(
            tio.toString(), "enc-test", null,
            java.util.List.of(), java.util.List.of(),
            java.util.List.of(), java.util.List.of());
        ds.encryptWithKey(key, Enums.EncryptionLevel.ACCESS_UNIT);
        ds.close();

        Path keyFile = tmp.resolve("k.bin");
        Files.write(keyFile, key);

        SpectralDataset opened = SpectralDataset.open(tio.toString());
        assertTrue(opened.isEncrypted(), "fixture should be encrypted");
        EncryptionTab tab = new EncryptionTab();
        OpenDataset open = new OpenDataset(tio.toString(), false, opened);
        tab.update(open, new DatasetTreeNode(
            TreeNodeKind.ENCRYPTION, "encryption", null));
        tab.decryptFromFile(keyFile);

        try (SpectralDataset reopened = SpectralDataset.open(tio.toString())) {
            assertFalse(reopened.isEncrypted(),
                "after decryptFromFile + reopen, dataset should be unencrypted");
        }
    }
}

package global.thalion.ttio.browser.transport;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for {@link TisEncoder}.
 */
class TisEncoderTest {

    private static final Path FIXTURE =
        Paths.get("../java/src/test/resources/ttio/minimal_ms.tio").toAbsolutePath();

    @Test
    void encodeProducesNonEmptyFile() throws Exception {
        assertTrue(Files.exists(FIXTURE), "fixture missing: " + FIXTURE);
        Path tis = TisEncoder.encodeToTempFile(FIXTURE.toString(), false);
        try {
            assertTrue(Files.exists(tis), "tempfile should exist");
            assertTrue(Files.size(tis) > 64,
                "encoded .tis should be > 64 bytes, got: " + Files.size(tis));
        } finally {
            Files.deleteIfExists(tis);
        }
    }

    @Test
    void encodeWithChecksumProducesLargerFile() throws Exception {
        assertTrue(Files.exists(FIXTURE), "fixture missing: " + FIXTURE);
        Path noChk   = TisEncoder.encodeToTempFile(FIXTURE.toString(), false);
        Path withChk = TisEncoder.encodeToTempFile(FIXTURE.toString(), true);
        try {
            long sizeNo  = Files.size(noChk);
            long sizeChk = Files.size(withChk);
            assertTrue(sizeChk > sizeNo,
                "checksum stream should be larger (" + sizeChk + " vs " + sizeNo + ")");
        } finally {
            Files.deleteIfExists(noChk);
            Files.deleteIfExists(withChk);
        }
    }

    @Test
    void encodedFileNameEndsWithTis() throws Exception {
        assertTrue(Files.exists(FIXTURE), "fixture missing: " + FIXTURE);
        Path tis = TisEncoder.encodeToTempFile(FIXTURE.toString(), false);
        try {
            assertTrue(tis.getFileName().toString().endsWith(".tis"),
                "temp file should end with .tis: " + tis);
        } finally {
            Files.deleteIfExists(tis);
        }
    }

    @Test
    void missingTioThrowsException() {
        // HDF5 provider throws Hdf5Errors.FileNotFoundException (a RuntimeException),
        // so we accept any Exception from a missing path.
        assertThrows(Exception.class,
            () -> TisEncoder.encodeToTempFile("/nonexistent/path/missing.tio", false));
    }
}

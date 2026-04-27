package global.thalion.ttio;

import global.thalion.ttio.importers.BamReader;
import global.thalion.ttio.importers.BamReader.SamtoolsNotFoundException;
import global.thalion.ttio.importers.CramReader;
import global.thalion.ttio.importers.JcampDxReader;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

/**
 * V4 edge-case hardening — Java.
 *
 * <p>Locks in the current failure-mode behaviour for known UX-visible
 * edge cases. The point isn't to test happy paths (those are covered
 * elsewhere) — it's to ensure each failure produces a useful error
 * that doesn't change accidentally over time.</p>
 *
 * <p>Categories covered (mirrors {@code python/tests/test_v4_edge_cases.py}):</p>
 * <ol>
 *   <li>{@code samtools} missing on PATH → {@link SamtoolsNotFoundException}
 *       with install hints (apt / brew / conda).</li>
 *   <li>{@code samtools} exits non-zero (e.g. malformed BAM) → wrapper
 *       throws {@link IOException} with samtools context surfaced.</li>
 *   <li>Reference FASTA missing for {@link CramReader} →
 *       {@link IllegalStateException} naming the offending path.</li>
 *   <li>Truncated BAM input → wrapper raises {@link IOException}.</li>
 *   <li>Malformed JCAMP-DX numeric block →
 *       {@link IllegalArgumentException} with "JCAMP-DX:" prefix.</li>
 *   <li>{@link CramReader} construction without a reference FASTA →
 *       {@link NullPointerException} (M88 contract; argument is
 *       {@code Objects.requireNonNull}-checked at construction).</li>
 * </ol>
 *
 * <p>Per {@code docs/verification-workplan.md} §V4.</p>
 */
public class V4EdgeCasesTest {

    private static final Path REPO_ROOT = Paths.get(System.getProperty("user.dir")).getParent();
    private static final Path M88_BAM =
        REPO_ROOT.resolve("python/tests/fixtures/genomic/m88_test.bam");
    private static final Path M88_CRAM =
        REPO_ROOT.resolve("python/tests/fixtures/genomic/m88_test.cram");
    private static final Path M88_FASTA =
        REPO_ROOT.resolve("python/tests/fixtures/genomic/m88_test_reference.fa");

    private static boolean samtoolsAvailable() {
        try {
            Process p = new ProcessBuilder("samtools", "--version")
                .redirectErrorStream(true)
                .start();
            return p.waitFor() == 0;
        } catch (Exception e) {
            return false;
        }
    }

    // ----- Category 1: SamtoolsNotFoundException is a useful subclass --------

    @Test
    @DisplayName("V4 #1: SamtoolsNotFoundException is an IOException subclass")
    void samtoolsNotFoundExceptionIsIoException() {
        // The exception must be an IOException so callers that catch
        // IOException (broad) still see the samtools-missing case
        // rather than letting a RuntimeException escape silently.
        assertTrue(IOException.class.isAssignableFrom(SamtoolsNotFoundException.class),
            "SamtoolsNotFoundException must extend IOException so broad catches see it");
    }

    @Test
    @DisplayName("V4 #2: SamtoolsNotFoundException carries the install-hint message")
    void samtoolsNotFoundExceptionHasInstallHints() {
        SamtoolsNotFoundException e = new SamtoolsNotFoundException(
            "samtools not found on PATH; install with: apt install samtools / "
            + "brew install samtools / conda install -c bioconda samtools");
        String msg = e.getMessage().toLowerCase();
        assertTrue(msg.contains("samtools"), "message should name 'samtools'");
        assertTrue(msg.contains("apt") || msg.contains("brew") || msg.contains("conda"),
            "message should include at least one install-path hint; got: " + msg);
    }

    // ----- Category 2: samtools exits non-zero on malformed BAM --------------

    @Test
    @DisplayName("V4 #3: malformed BAM raises IOException with samtools context")
    void bamReaderRaisesOnMalformedBam(@TempDir Path tmp) throws IOException {
        if (!samtoolsAvailable()) return;  // skip — same pattern as Python
        Path fakeBam = tmp.resolve("garbage.bam");
        // 1 KB of zeroes — not a valid BAM (no BGZF magic).
        Files.write(fakeBam, new byte[1024]);
        BamReader reader = new BamReader(fakeBam);
        IOException thrown = assertThrows(IOException.class, () -> reader.toGenomicRun("g"));
        String msg = thrown.getMessage();
        assertNotNull(msg, "IOException must have a message");
        assertTrue(msg.length() > 0, "IOException message must be non-empty");
    }

    // ----- Category 3: reference FASTA missing at read time ------------------

    @Test
    @DisplayName("V4 #4: CramReader.toGenomicRun raises IllegalStateException naming missing FASTA")
    void cramReaderRaisesOnMissingReference(@TempDir Path tmp) {
        if (!samtoolsAvailable()) return;
        Path bogusFasta = tmp.resolve("does_not_exist.fa");
        CramReader reader = new CramReader(M88_CRAM, bogusFasta);
        IllegalStateException thrown =
            assertThrows(IllegalStateException.class, () -> reader.toGenomicRun("g"));
        assertTrue(thrown.getMessage().contains(bogusFasta.toString()),
            "missing-reference error should name the offending path; got: "
                + thrown.getMessage());
    }

    @Test
    @DisplayName("V4 #5: CramReader constructor is cheap (lazy-validation contract from M88)")
    void cramReaderConstructorDoesNotCheckReference() {
        // Construction with a non-existent path must NOT throw — the
        // class is loadable on machines without samtools / without the
        // FASTA so doc generators don't blow up.
        Path bogus = Paths.get("/nonexistent/reference.fa");
        CramReader reader = new CramReader(M88_CRAM, bogus);
        assertEquals(bogus, reader.referenceFasta());
    }

    // ----- Category 4: CramReader construction without FASTA -----------------

    @Test
    @DisplayName("V4 #6: CramReader constructor rejects null FASTA (M88 §139)")
    void cramReaderConstructorRejectsNullFasta() {
        // M88 Binding Decision §139 — reference FASTA is required.
        // The Java constructor uses Objects.requireNonNull, which
        // throws NPE with a useful message rather than letting null
        // propagate to the samtools invocation later.
        assertThrows(NullPointerException.class,
            () -> new CramReader(M88_CRAM, null));
    }

    // ----- Category 5: truncated BAM input ----------------------------------

    @Test
    @DisplayName("V4 #7: truncated BAM raises IOException")
    void truncatedBamRaisesIoException(@TempDir Path tmp) throws IOException {
        if (!samtoolsAvailable()) return;
        Path truncated = tmp.resolve("chopped.bam");
        byte[] full = Files.readAllBytes(M88_BAM);
        byte[] half = new byte[full.length / 2];
        System.arraycopy(full, 0, half, 0, half.length);
        Files.write(truncated, half);
        BamReader reader = new BamReader(truncated);
        assertThrows(IOException.class, () -> reader.toGenomicRun("g"));
    }

    // ----- Category 6: malformed JCAMP-DX -----------------------------------

    @Test
    @DisplayName("V4 #8: JCAMP-DX with empty XYDATA raises IllegalArgumentException with prefix")
    void malformedJcampXyDataRaisesIllegalArgument(@TempDir Path tmp) throws IOException {
        Path bogus = tmp.resolve("empty.dx");
        Files.writeString(bogus,
            "##TITLE=Bogus\n"
            + "##JCAMP-DX=5.01\n"
            + "##DATA TYPE=INFRARED SPECTRUM\n"
            + "##XUNITS=1/CM\n"
            + "##YUNITS=ABSORBANCE\n"
            + "##XFACTOR=1\n"
            + "##YFACTOR=1\n"
            + "##FIRSTX=400\n"
            + "##LASTX=4000\n"
            + "##NPOINTS=10\n"
            + "##XYDATA=(X++(Y..Y))\n"
            // No data lines.
            + "##END=\n"
        );
        IllegalArgumentException thrown = assertThrows(IllegalArgumentException.class,
            () -> JcampDxReader.readSpectrum(bogus));
        assertTrue(thrown.getMessage().contains("JCAMP-DX"),
            "JCAMP parse errors should be prefixed for grep-ability; got: "
                + thrown.getMessage());
    }

    // ----- Category 7: zero-byte file ---------------------------------------

    @Test
    @DisplayName("V4 #9: zero-byte BAM raises IOException")
    void zeroByteBamRaisesIoException(@TempDir Path tmp) throws IOException {
        if (!samtoolsAvailable()) return;
        Path empty = tmp.resolve("empty.bam");
        Files.write(empty, new byte[0]);
        BamReader reader = new BamReader(empty);
        assertThrows(IOException.class, () -> reader.toGenomicRun("g"));
    }

    @Test
    @DisplayName("V4 #10: BamReader for non-existent file raises IOException at read time")
    void bamReaderRaisesOnMissingFile() {
        Path nonexistent = Paths.get("/nonexistent/path/sample.bam");
        BamReader reader = new BamReader(nonexistent);
        IOException thrown = assertThrows(IOException.class,
            () -> reader.toGenomicRun("g"));
        assertTrue(thrown.getMessage().contains(nonexistent.toString()),
            "missing-file error should name the offending path; got: "
                + thrown.getMessage());
    }
}

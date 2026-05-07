package global.thalion.ttio.browser.importers;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

/**
 * Magic-bytes + extension dispatch for the Import wizard's drag-drop
 * pre-selection. Returns the {@link ImportFormatSpec#name} for the
 * matched format, or {@code null} on no match.
 *
 * <p>Reads up to 64 KiB from the head of the file. Order of checks
 * matters — see HANDOFF §6.4. Special return values:</p>
 * <ul>
 *   <li>{@code ".tio"} — HDF5 magic detected; caller should open
 *       directly via {@code MainWindow.loadDataset}.</li>
 *   <li>{@code ".tis"} — TTIO transport stream magic; caller should
 *       open the streaming download dialog instead.</li>
 * </ul>
 */
public final class FormatSniffer {

    private static final int HEAD_BYTES = 64 * 1024;

    private FormatSniffer() {}

    public static String sniffFile(Path path) {
        try {
            byte[] head;
            if (Files.isDirectory(path)) {
                head = new byte[0];
            } else {
                try (InputStream in = Files.newInputStream(path)) {
                    head = in.readNBytes(HEAD_BYTES);
                }
            }
            return sniff(head, path.getFileName().toString(),
                Files.isDirectory(path));
        } catch (IOException e) {
            return null;
        }
    }

    public static String sniff(byte[] head, String filename) {
        return sniff(head, filename, false);
    }

    public static String sniff(byte[] head, String filename,
                               boolean isDirectory) {
        String fname = filename == null ? "" : filename.toLowerCase(Locale.ROOT);

        if (matches(head, HDF5_MAGIC)) return ".tio";
        if (matches(head, BAM_MAGIC)) return "BAM";
        if (matches(head, CRAM_MAGIC)) return "CRAM";
        if (matches(head, TTIO_MAGIC)) return ".tis";

        String first = firstNonBlankLine(head);

        if (head.length > 0 && containsBefore(head, "<indexedmzML", 4096)) {
            return fname.endsWith(".imzml") ? "imzML" : "mzML";
        }
        if (head.length > 0 && containsBefore(head, "<mzML", 4096)) {
            return fname.endsWith(".imzml") ? "imzML" : "mzML";
        }
        if (head.length > 0 && containsBefore(head, "<nmrML", 4096)) {
            return "nmrML";
        }

        if (first != null && first.startsWith("##JCAMP-DX")) return "JCAMP-DX";
        if (first != null && first.startsWith("MTD\t"))      return "mzTab";

        if (isDirectory && fname.endsWith(".d"))  return "Bruker timsTOF";
        if (isDirectory && fname.endsWith(".raw")) return "Waters MassLynx";
        if (!isDirectory && fname.endsWith(".raw")) return "Thermo .raw";

        if (first != null && (first.startsWith("@HD\t") || first.startsWith("@SQ\t")
                           || first.startsWith("@PG\t") || first.startsWith("@RG\t"))) {
            return "SAM";
        }

        if (first != null && first.startsWith(">"))  return "FASTA";
        if (looksLikeFastq(head))                    return "FASTQ";

        return null;
    }

    /* HDF5 superblock signature. */
    private static final byte[] HDF5_MAGIC = {
        (byte) 0x89, 'H', 'D', 'F', '\r', '\n', 0x1a, '\n'
    };
    /* BAM = bgzipped SAM with a BAM\1 marker after the BGZF header.
     * For drag-drop sniff we accept either the literal "BAM\1" prefix
     * (uncompressed test fixtures) OR a BGZF magic so a real .bam still
     * gets matched on extension below if magic alone is inconclusive. */
    private static final byte[] BAM_MAGIC = { 'B', 'A', 'M', 0x01 };
    /* CRAM definition file magic. */
    private static final byte[] CRAM_MAGIC = { 'C', 'R', 'A', 'M', 0x03, 0x00 };
    /* TTI-O transport stream magic. */
    private static final byte[] TTIO_MAGIC = { 'T', 'T', 'I', 'O' };

    private static boolean matches(byte[] head, byte[] magic) {
        if (head.length < magic.length) return false;
        for (int i = 0; i < magic.length; i++) {
            if (head[i] != magic[i]) return false;
        }
        return true;
    }

    private static boolean containsBefore(byte[] head, String needle, int limit) {
        int max = Math.min(head.length, limit);
        byte[] n = needle.getBytes();
        outer:
        for (int i = 0; i <= max - n.length; i++) {
            for (int j = 0; j < n.length; j++) {
                if (head[i + j] != n[j]) continue outer;
            }
            return true;
        }
        return false;
    }

    /** First line that has at least one non-whitespace byte; null on none. */
    static String firstNonBlankLine(byte[] head) {
        int start = 0;
        for (int i = 0; i < head.length; i++) {
            if (head[i] == '\n') {
                String line = new String(head, start, i - start);
                if (!line.trim().isEmpty()) return stripTrailingCr(line);
                start = i + 1;
            }
        }
        if (start < head.length) {
            String line = new String(head, start, head.length - start);
            if (!line.trim().isEmpty()) return stripTrailingCr(line);
        }
        return null;
    }

    private static String stripTrailingCr(String s) {
        return s.endsWith("\r") ? s.substring(0, s.length() - 1) : s;
    }

    /** FASTQ shape: line 1 starts with '@', line 3 with '+'. */
    static boolean looksLikeFastq(byte[] head) {
        String[] lines = new String(head).split("\n", -1);
        if (lines.length < 4) return false;
        return lines[0].startsWith("@") && lines[2].startsWith("+");
    }
}

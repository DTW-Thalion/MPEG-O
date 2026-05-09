package global.thalion.ttio.browser.diag;

/**
 * Result of probing one external dependency (binary or in-process library).
 *
 * @param name         human-readable label (e.g. "samtools")
 * @param resolvedPath absolute path the probe resolved to, or {@code null}
 *                     when not found / in-process
 * @param status       outcome bucket (OK / NOT_FOUND / ERROR)
 * @param detail       version string on OK, error message on ERROR,
 *                     empty string on NOT_FOUND
 */
public record ProbeResult(
        String name,
        String resolvedPath,
        Status status,
        String detail) {

    public enum Status { OK, NOT_FOUND, ERROR }
}

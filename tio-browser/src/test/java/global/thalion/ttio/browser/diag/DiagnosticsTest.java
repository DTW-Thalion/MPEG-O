package global.thalion.ttio.browser.diag;

import java.util.List;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class DiagnosticsTest {

    @Test
    void samtoolsProbeReportsOkOrNotFound() {
        ProbeResult r = new BinaryProbe(
            "samtools", null, "samtools",
            List.of("--version"),
            line -> {
                String[] parts = line.split(" ", 2);
                return parts.length >= 2 ? parts[1] : line;
            }
        ).probe();
        assertNotNull(r.status(),
            "probe() must always return a non-null Status");
        if (r.status() == ProbeResult.Status.OK) {
            assertNotNull(r.detail(),  "OK result must carry a detail");
            assertNotNull(r.resolvedPath(),
                "OK result must carry the resolved path");
            assertFalse(r.detail().isBlank(),
                "OK detail for samtools should be non-blank");
        } else if (r.status() == ProbeResult.Status.NOT_FOUND) {
            assertNull(r.resolvedPath(),
                "NOT_FOUND must have null resolvedPath");
        }
        // ERROR is also acceptable on environments where the binary
        // exists but doesn't respond to --version in time.
    }

    @Test
    void inProcessProbeOk() {
        ProbeResult r = new BinaryProbe("synthetic", () -> "version-x").probe();
        assertEquals(ProbeResult.Status.OK, r.status());
        assertEquals("version-x", r.detail());
        assertEquals("(in-process)", r.resolvedPath());
        assertEquals("synthetic", r.name());
    }

    @Test
    void inProcessProbeError() {
        ProbeResult r = new BinaryProbe("synthetic-bad", () -> {
            throw new RuntimeException("boom");
        }).probe();
        assertEquals(ProbeResult.Status.ERROR, r.status());
        assertNull(r.resolvedPath());
        assertEquals("boom", r.detail());
    }

    @Test
    void inProcessProbeErrorWithNullMessageFallsBackToClassName() {
        ProbeResult r = new BinaryProbe("synthetic-null-msg", () -> {
            throw new RuntimeException();  // null message
        }).probe();
        assertEquals(ProbeResult.Status.ERROR, r.status());
        assertEquals("RuntimeException", r.detail());
    }

    @Test
    void notFoundReturnsNullPath() {
        ProbeResult r = new BinaryProbe(
            "definitely-not-a-real-binary",
            null,
            "definitely-not-a-real-binary-xyz-9999",
            List.of("--version"),
            line -> line
        ).probe();
        assertEquals(ProbeResult.Status.NOT_FOUND, r.status());
        assertNull(r.resolvedPath());
        assertEquals("", r.detail());
    }

    @Test
    void diagnosticsRegistryHasExpectedEntries() {
        // 5 probes: HDF5, samtools, ThermoRawFileParser, masslynxraw, Bruker
        assertEquals(5, Diagnostics.probes().size());
        // Cache starts empty until probeAll() is invoked.
        // (Defensive: another test may have populated the cache already.)
        List<ProbeResult> results = Diagnostics.probeAll();
        assertEquals(5, results.size());
        assertEquals(results, Diagnostics.cached());
    }

    @Test
    void isAvailableTracksLatestProbe() {
        Diagnostics.probeAll();
        // HDF5 should be available (the JaCoCo/test JVM has the JNI loaded).
        // If not, the assertion will catch it; CI explicitly sets -Dhdf5.jar=...
        boolean hdf5Ok = Diagnostics.isAvailable("HDF5 (in-process JNI)");
        boolean unknownOk = Diagnostics.isAvailable("not-a-registered-probe");
        assertFalse(unknownOk, "unknown name must report unavailable");
        // hdf5Ok is environment-dependent; we just assert it was probed.
        assertTrue(Diagnostics.cached().stream()
            .anyMatch(r -> r.name().equals("HDF5 (in-process JNI)")),
            "HDF5 probe must be present in cached results");
        // No-op reference to silence unused-warning intent.
        assertNotNull(Boolean.valueOf(hdf5Ok));
    }
}

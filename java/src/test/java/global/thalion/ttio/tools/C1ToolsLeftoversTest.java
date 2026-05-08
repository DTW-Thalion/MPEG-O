package global.thalion.ttio.tools;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * C1.2 -- leftover Java tools/ coverage push.
 * Targets CanonicalJson 18.7%%, DumpIdentifications 37.7%%,
 * TransportServerCli 10.5%%.
 *
 * <p>CLI mains are run via {@link CliSubprocessRunner} to avoid the
 * Java 21 incompatibility with {@code System.setSecurityManager}.
 * Pure static-helper tests (CanonicalJson) run in-process.</p>
 */
public class C1ToolsLeftoversTest {

    @Test
    @DisplayName("C1.2 #1: CanonicalJson.escapeString covers control + quote/backslash + non-ASCII")
    void canonicalEscapeString() {
        assertEquals("\"plain\"", CanonicalJson.escapeString("plain"));
        assertEquals("\"a\\\"b\\\\c\"", CanonicalJson.escapeString("a\"b\\c"));
        assertTrue(CanonicalJson.escapeString("\n").contains("\\n"));
        assertTrue(CanonicalJson.escapeString("\t").contains("\\t"));
        assertTrue(CanonicalJson.escapeString("\r").contains("\\r"));
        String esc = CanonicalJson.escapeString("");
        assertTrue(esc.contains("u00"),
            "control char escape should mention u00; got: " + esc);
        String hi = CanonicalJson.escapeString("é");
        assertNotNull(hi);
    }

    @Test
    @DisplayName("C1.2 #2: CanonicalJson.formatFloat fixed + scientific paths")
    void canonicalFormatFloat() {
        assertEquals("0", CanonicalJson.formatFloat(0.0));
        assertEquals("-0", CanonicalJson.formatFloat(-0.0));
        String neg = CanonicalJson.formatFloat(-2.5);
        assertTrue(neg.startsWith("-"));
        String small = CanonicalJson.formatFloat(1e-10);
        assertTrue(small.contains("e-") || small.startsWith("0."));
        String big = CanonicalJson.formatFloat(1.5e20);
        assertTrue(big.contains("e+"));
        String pi = CanonicalJson.formatFloat(3.14159);
        assertTrue(pi.startsWith("3.14"));
        assertNotNull(CanonicalJson.formatFloat(10.0));
    }

    @Test
    @DisplayName("C1.2 #3: CanonicalJson.formatFloat NaN + +/-inf branches")
    void canonicalFormatFloatSpecial() {
        assertEquals("nan", CanonicalJson.formatFloat(Double.NaN));
        assertEquals("inf", CanonicalJson.formatFloat(Double.POSITIVE_INFINITY));
        assertEquals("-inf", CanonicalJson.formatFloat(Double.NEGATIVE_INFINITY));
    }

    @Test
    @DisplayName("C1.2 #4: CanonicalJson.formatInt + formatValue dispatch")
    void canonicalFormatIntAndValue() {
        assertEquals("0", CanonicalJson.formatInt(0L));
        assertEquals("-42", CanonicalJson.formatInt(-42L));
        assertEquals("9223372036854775807",
            CanonicalJson.formatInt(Long.MAX_VALUE));

        assertEquals("0", CanonicalJson.formatValue(0L));
        assertEquals("0", CanonicalJson.formatValue(0.0));
        assertEquals("\"hi\"", CanonicalJson.formatValue("hi"));
        assertEquals("5", CanonicalJson.formatValue(5));
    }

    @Test
    @DisplayName("C1.2 #5: CanonicalJson.formatRecord + formatTopLevel")
    void canonicalFormatRecordAndTopLevel() {
        Map<String, Object> rec = new HashMap<>();
        rec.put("name", "alpha");
        rec.put("score", 0.95);
        rec.put("rank", 1L);
        String s = CanonicalJson.formatRecord(rec);
        assertTrue(s.startsWith("{") && s.endsWith("}"));
        int nameIdx = s.indexOf("\"name\"");
        int rankIdx = s.indexOf("\"rank\"");
        int scoreIdx = s.indexOf("\"score\"");
        assertTrue(nameIdx < rankIdx && rankIdx < scoreIdx,
            "keys alphabetical: " + s);

        Map<String, List<Map<String, Object>>> sections = new LinkedHashMap<>();
        sections.put("identifications", List.of(rec));
        sections.put("quantifications", List.of());
        String top = CanonicalJson.formatTopLevel(sections);
        assertTrue(top.startsWith("{"));
        assertTrue(top.contains("\"identifications\""));
        assertTrue(top.contains("\"quantifications\""));
    }

    private Path buildRichFixture(Path dir, String name) {
        String path = dir.resolve(name).toString();
        int nSpectra = 2;
        double[] mz = { 100.0, 101.0, 102.0, 103.0, 200.0, 201.0, 202.0, 203.0 };
        double[] intensity = { 10, 20, 30, 40, 50, 60, 70, 80 };
        long[] offsets = { 0, 4 };
        int[] lengths = { 4, 4 };
        double[] rts = { 1.0, 2.0 };
        int[] msLevels = { 1, 1 };
        int[] pols = { 1, 1 };
        double[] pmzs = { 0.0, 0.0 };
        int[] pcs = { 0, 0 };
        double[] bpis = { 40.0, 80.0 };

        global.thalion.ttio.SpectrumIndex idx =
            new global.thalion.ttio.SpectrumIndex(nSpectra, offsets, lengths,
                rts, msLevels, pols, pmzs, pcs, bpis);
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", mz);
        channels.put("intensity", intensity);

        global.thalion.ttio.AcquisitionRun run =
            new global.thalion.ttio.AcquisitionRun(
                "run_0001",
                global.thalion.ttio.Enums.AcquisitionMode.MS1_DDA,
                idx,
                new global.thalion.ttio.InstrumentConfig("","","","","",""),
                channels, List.of(), List.of(), null, 0.0);

        global.thalion.ttio.Identification ident =
            new global.thalion.ttio.Identification(
                "run_0001", 0, "CHEBI:15377", 0.95,
                List.of("MS:1001143", "MS:1002338"));
        global.thalion.ttio.Identification ident2 =
            new global.thalion.ttio.Identification(
                "run_0001", 1, "CHEBI:17234", 0.87,
                List.of("MS:1002361"));

        global.thalion.ttio.Quantification quant =
            new global.thalion.ttio.Quantification(
                "CHEBI:15377", "sample_001", 1234.5, "median");

        global.thalion.ttio.ProvenanceRecord prov =
            new global.thalion.ttio.ProvenanceRecord(
                1700000000L, "TTI-O reference Java 1.1.1",
                Map.of("threshold", "0.5"),
                List.of("file:///raw/sample.raw"),
                List.of("file:///out/sample.tio"));

        try (global.thalion.ttio.SpectralDataset ds =
                global.thalion.ttio.SpectralDataset.create(path,
                    "C1.2 rich fixture", "ISA-C1-2",
                    List.of(run), List.of(ident, ident2),
                    List.of(quant), List.of(prov))) {
        }
        return Path.of(path);
    }

    @Test
    @DisplayName("C1.2 #6: DumpIdentifications on rich fixture exits 0 with sections present")
    void dumpIdentsRichFixture(@TempDir Path tmp) throws Exception {
        Path src = buildRichFixture(tmp, "dump_rich.tio");
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(
            DumpIdentifications.class, src.toString());
        assertEquals(0, r.exitCode, "DumpIdentifications should exit 0");
        String body = r.stdout;
        assertTrue(body.startsWith("{"),
            "JSON output; got: " + body.substring(0, Math.min(80, body.length())));
        assertTrue(body.contains("identifications"));
        assertTrue(body.contains("quantifications"));
        assertTrue(body.contains("provenance"));
    }

    @Test
    @DisplayName("C1.2 #7: DumpIdentifications with too many args fails")
    void dumpIdentsTooManyArgs() throws Exception {
        CliSubprocessRunner.CliResult r = CliSubprocessRunner.run(
            DumpIdentifications.class, "a.tio", "b.tio");
        assertNotEquals(0, r.exitCode);
    }
}

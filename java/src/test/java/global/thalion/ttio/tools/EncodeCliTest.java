package global.thalion.ttio.tools;

import static org.junit.jupiter.api.Assertions.*;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.exporters.MzMLWriter;

/** JT9: {@link EncodeCli} parses args and dispatches through
 *  {@link global.thalion.ttio.importers.ImporterRegistry}. */
class EncodeCliTest {

    @Test
    void unknownFormatExits3() {
        int rc = EncodeCli.run(new String[]{
            "--input", "x.xyz", "--format", "xyz", "--output", "o.tio"});
        assertEquals(3, rc);
    }

    @Test
    void listFormatsExits0() {
        int rc = EncodeCli.run(new String[]{"--list-formats"});
        assertEquals(0, rc);
    }

    @Test
    void encodesMzml(@TempDir Path tmp) throws Exception {
        // Build a tiny one-run mzML on disk via the exporter, then encode
        // it back through the registry.
        Path mzml = tmp.resolve("tiny.mzML");
        MzMLWriter.write(minimalRun("run1"), mzml.toString());

        Path out = tmp.resolve("e.tio");
        int rc = EncodeCli.run(new String[]{
            "--input", mzml.toString(),
            "--format", "mzml",
            "--output", out.toString()});
        assertEquals(0, rc);
        assertTrue(Files.exists(out));
    }

    private static AcquisitionRun minimalRun(String name) {
        SpectrumIndex idx = new SpectrumIndex(
            1, new long[]{0L}, new int[]{1},
            new double[]{0.1}, new int[]{1}, new int[]{1},
            new double[]{0.0}, new int[]{0}, new double[]{0.0});
        Map<String, double[]> channels = new LinkedHashMap<>();
        channels.put("mz", new double[]{100.0});
        channels.put("intensity", new double[]{1000.0});
        InstrumentConfig cfg = new InstrumentConfig(
            "vendor", "model", "sn", "ESI", "QTOF", "MCP");
        return new AcquisitionRun(
            name, AcquisitionMode.MS1_DDA, idx, cfg, channels,
            List.of(), List.of(), null, 0.0);
    }
}

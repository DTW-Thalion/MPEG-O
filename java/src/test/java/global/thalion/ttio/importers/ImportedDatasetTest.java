package global.thalion.ttio.importers;

import static org.junit.jupiter.api.Assertions.*;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import global.thalion.ttio.*;
import global.thalion.ttio.Enums.AcquisitionMode;

class ImportedDatasetTest {

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

    @Test
    void writeRoundTripsAnalyticalRun(@TempDir Path tmp) throws Exception {
        ImportedDataset draft = new ImportedDataset();
        draft.title = "t";
        draft.isaInvestigationId = "TTIO:t";
        draft.runs.add(minimalRun("run1"));
        Path out = tmp.resolve("d.tio");
        Path returned = draft.write(out);
        assertEquals(out, returned);
        try (SpectralDataset ds = SpectralDataset.open(out.toString())) {
            assertFalse(ds.msRuns().isEmpty());
        }
    }
}

package global.thalion.ttio.importers;

import static org.junit.jupiter.api.Assertions.*;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums.AcquisitionMode;
import global.thalion.ttio.InstrumentConfig;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.SpectrumIndex;
import global.thalion.ttio.exporters.MzMLWriter;
import global.thalion.ttio.importers.readers.BamReaderAdapter;
import global.thalion.ttio.importers.readers.BrukerReaderAdapter;
import global.thalion.ttio.importers.readers.CramReaderAdapter;
import global.thalion.ttio.importers.readers.ImzMLReaderAdapter;
import global.thalion.ttio.importers.readers.JcampDxReaderAdapter;
import global.thalion.ttio.importers.readers.MzMLReaderAdapter;
import global.thalion.ttio.importers.readers.MzTabReaderAdapter;
import global.thalion.ttio.importers.readers.NmrMLReaderAdapter;
import global.thalion.ttio.importers.readers.SamReaderAdapter;
import global.thalion.ttio.importers.readers.ThermoRawReaderAdapter;
import global.thalion.ttio.importers.readers.WatersMassLynxReaderAdapter;

/** JT6: every per-format adapter implements {@link Reader}, and the mzML
 *  adapter performs a real parse → {@link ImportedDataset} → {@code .tio}
 *  round-trip. */
class FormatReadersTest {

    @Test
    void everyAdapterIsAReader() {
        assertTrue(new MzMLReaderAdapter()           instanceof Reader);
        assertTrue(new MzTabReaderAdapter()          instanceof Reader);
        assertTrue(new ImzMLReaderAdapter()          instanceof Reader);
        assertTrue(new NmrMLReaderAdapter()          instanceof Reader);
        assertTrue(new ThermoRawReaderAdapter()      instanceof Reader);
        assertTrue(new WatersMassLynxReaderAdapter() instanceof Reader);
        assertTrue(new JcampDxReaderAdapter()        instanceof Reader);
        assertTrue(new BrukerReaderAdapter()         instanceof Reader);
        assertTrue(new BamReaderAdapter()            instanceof Reader);
        assertTrue(new SamReaderAdapter()            instanceof Reader);
        assertTrue(new CramReaderAdapter()           instanceof Reader);
    }

    @Test
    void mzmlAdapterRoundTrips(@TempDir Path tmp) throws Exception {
        // Build a tiny one-run mzML on disk via the exporter.
        AcquisitionRun run = minimalRun("run1");
        Path mzml = tmp.resolve("tiny.mzML");
        MzMLWriter.write(run, mzml.toString());

        // Parse it back through the adapter → ImportedDataset.
        ImportedDataset ds = new MzMLReaderAdapter()
            .read(List.of(mzml.toString()), Map.of(), null);
        assertNotNull(ds);
        assertFalse(ds.runs.isEmpty() && ds.spectralStreams.isEmpty(), "adapter produced no runs");

        // Write the draft and reopen: at least one MS run must survive.
        Path out = tmp.resolve("d.tio");
        ds.write(out);
        try (SpectralDataset reopened = SpectralDataset.open(out.toString())) {
            assertFalse(reopened.msRuns().isEmpty());
        }
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

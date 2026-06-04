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

    @Test
    void fastaFastqAreDelegatedExit3() {
        assertEquals(3, EncodeCli.run(new String[]{
            "--input", "x.fasta", "--format", "fasta", "--output", "o.tio"}));
        assertEquals(3, EncodeCli.run(new String[]{
            "--input", "x.fastq", "--format", "fastq", "--output", "o.tio"}));
    }

    @Test
    void missingArgsExits2() {
        // no --output
        assertEquals(2, EncodeCli.run(new String[]{
            "--input", "x.mzML", "--format", "mzml"}));
        // no --input
        assertEquals(2, EncodeCli.run(new String[]{
            "--format", "mzml", "--output", "o.tio"}));
        // nothing
        assertEquals(2, EncodeCli.run(new String[]{}));
    }

    @Test
    void danglingOptionValueExits2() {
        assertEquals(2, EncodeCli.run(new String[]{"--input"}));
        assertEquals(2, EncodeCli.run(new String[]{"--format"}));
        assertEquals(2, EncodeCli.run(new String[]{"--output"}));
        assertEquals(2, EncodeCli.run(new String[]{"--extra"}));
    }

    @Test
    void unknownArgumentExits2() {
        assertEquals(2, EncodeCli.run(new String[]{"--nope"}));
    }

    @Test
    void malformedExtraExits2() {
        assertEquals(2, EncodeCli.run(new String[]{
            "--input", "x.mzML", "--format", "mzml",
            "--output", "o.tio", "--extra", "noequals"}));
    }

    @Test
    void importerFailureOnMissingInputExits2(@TempDir Path tmp) {
        // A registry format whose input file does not exist → importer
        // throws → exit 2.
        int rc = EncodeCli.run(new String[]{
            "--input", tmp.resolve("does-not-exist.mzML").toString(),
            "--format", "mzml",
            "--output", tmp.resolve("o.tio").toString()});
        assertEquals(2, rc);
    }

    @Test
    void encodesMzmlWithExtraOpt(@TempDir Path tmp) throws Exception {
        Path mzml = tmp.resolve("tiny2.mzML");
        MzMLWriter.write(minimalRun("run1"), mzml.toString());
        Path out = tmp.resolve("e2.tio");
        int rc = EncodeCli.run(new String[]{
            "--input", mzml.toString(),
            "--format", "mzml",
            "--output", out.toString(),
            "--extra", "title=custom"});
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

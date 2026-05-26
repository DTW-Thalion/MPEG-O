/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import global.thalion.ttio.io.ProgressSink;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Stage C per-spectrum {@link ProgressSink} wiring for {@link MzMLReader}.
 *
 * <p>Asserts that the new sink overload fires periodic mid-parse
 * callbacks every {@link MzMLReader#PROGRESS_INTERVAL_SPECTRA} spectra
 * and a final {@code done==total} callback at end-of-document.</p>
 */
class MzMLReaderProgressTest {

    /** Synthesise an mzML 1.1 file with {@code n} minimal spectra. Each
     *  spectrum carries a 2-peak m/z + intensity array so the SAX
     *  state-machine drives through every required end-tag. */
    private static Path writeSyntheticMzML(Path tmp, String name, int n)
            throws IOException {
        Path out = tmp.resolve(name);
        byte[] mzBytes = new byte[16];
        byte[] intBytes = new byte[16];
        // Two doubles; values don't matter for progress assertions.
        // Default LE zero-bytes.
        String mzB64  = Base64.getEncoder().encodeToString(mzBytes);
        String intB64 = Base64.getEncoder().encodeToString(intBytes);

        try (BufferedWriter w = Files.newBufferedWriter(out)) {
            w.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
            w.write("<mzML xmlns=\"http://psi.hupo.org/ms/mzml\" version=\"1.1.0\">\n");
            w.write("  <run id=\"r\"><spectrumList count=\"" + n + "\">\n");
            for (int i = 0; i < n; i++) {
                w.write("    <spectrum index=\"" + i + "\" id=\"scan=" + i
                    + "\" defaultArrayLength=\"2\">\n");
                w.write("      <cvParam cvRef=\"MS\" accession=\"MS:1000511\""
                    + " name=\"ms level\" value=\"1\"/>\n");
                w.write("      <binaryDataArrayList count=\"2\">\n");
                w.write("        <binaryDataArray encodedLength=\""
                    + mzB64.length() + "\">\n");
                w.write("          <cvParam cvRef=\"MS\" accession=\"MS:1000523\""
                    + " name=\"64-bit float\"/>\n");
                w.write("          <cvParam cvRef=\"MS\" accession=\"MS:1000514\""
                    + " name=\"m/z array\"/>\n");
                w.write("          <binary>" + mzB64 + "</binary>\n");
                w.write("        </binaryDataArray>\n");
                w.write("        <binaryDataArray encodedLength=\""
                    + intB64.length() + "\">\n");
                w.write("          <cvParam cvRef=\"MS\" accession=\"MS:1000523\""
                    + " name=\"64-bit float\"/>\n");
                w.write("          <cvParam cvRef=\"MS\" accession=\"MS:1000515\""
                    + " name=\"intensity array\"/>\n");
                w.write("          <binary>" + intB64 + "</binary>\n");
                w.write("        </binaryDataArray>\n");
                w.write("      </binaryDataArrayList>\n");
                w.write("    </spectrum>\n");
            }
            w.write("  </spectrumList></run>\n");
            w.write("</mzML>\n");
        }
        return out;
    }

    @Test
    void mzmlReader_emits_progress_per_hundred_spectra(@TempDir Path tmp)
            throws Exception {
        // 250 spectra → 2 mid-parse fires (at 100 and 200) + 1 final fire.
        Path mz = writeSyntheticMzML(tmp, "progress.mzML", 250);

        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        MzMLReader.read(mz.toFile(), sink);

        assertTrue(callbackCount.get() >= 2,
            "expected at least 2 callbacks for 250 spectra, got "
                + callbackCount.get());
        assertEquals(250L, lastDone.get(),
            "final callback should report exact spectrum count");
        assertEquals(250L, lastTotal.get(),
            "final callback should set total == done");
    }

    @Test
    void mzmlReader_emits_final_callback_for_small_inputs(@TempDir Path tmp)
            throws Exception {
        // 3 spectra → 0 mid-parse fires + 1 final fire.
        Path mz = writeSyntheticMzML(tmp, "small.mzML", 3);

        AtomicLong lastDone = new AtomicLong(-1L);
        AtomicLong lastTotal = new AtomicLong(-1L);
        AtomicInteger callbackCount = new AtomicInteger();
        ProgressSink sink = (done, total) -> {
            callbackCount.incrementAndGet();
            lastDone.set(done);
            lastTotal.set(total);
        };

        MzMLReader.read(mz.toFile(), sink);

        assertTrue(callbackCount.get() >= 1,
            "final callback must always fire even for small inputs");
        assertEquals(3L, lastDone.get(), "final done == spectrum count");
        assertEquals(3L, lastTotal.get(), "final total == done");
    }

    @Test
    void mzmlReader_default_overload_uses_discard_sink(@TempDir Path tmp)
            throws Exception {
        // No sink → must not throw (uses ProgressSink.discard()).
        Path mz = writeSyntheticMzML(tmp, "tiny.mzML", 2);
        var run = MzMLReader.read(mz.toFile());
        // buildRun returns null when specCount == 0; with 2 well-formed
        // spectra we expect a non-null result.
        org.junit.jupiter.api.Assertions.assertEquals(2,
            run.spectrumIndex().count(),
            "no-sink overload should parse spectra as before");
    }
}

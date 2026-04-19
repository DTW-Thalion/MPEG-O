/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo.importers;

import com.dtwthalion.mpgo.AcquisitionRun;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermission;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.9 M63 — Waters MassLynx importer. Cross-language counterpart
 * of {@code TestWatersMassLynxReader.m} and
 * {@code test_waters_masslynx.py}. Uses a POSIX shell mock converter
 * so the delegation pipeline runs without Waters tooling installed.
 */
final class WatersMassLynxReaderTest {

    private static final String STUB_MZML = ""
        + "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        + "<mzML xmlns=\"http://psi.hupo.org/ms/mzml\" version=\"1.1.0\">\n"
        + "  <cvList count=\"2\">\n"
        + "    <cv id=\"MS\" fullName=\"PSI MS\" version=\"4.1.0\"/>\n"
        + "    <cv id=\"UO\" fullName=\"UO\" version=\"2020-03-10\"/>\n"
        + "  </cvList>\n"
        + "  <fileDescription><fileContent>\n"
        + "    <cvParam cvRef=\"MS\" accession=\"MS:1000580\" name=\"MSn spectrum\"/>\n"
        + "  </fileContent></fileDescription>\n"
        + "  <softwareList count=\"1\"><software id=\"mock_masslynx\" version=\"0.0\"/></softwareList>\n"
        + "  <instrumentConfigurationList count=\"1\"><instrumentConfiguration id=\"IC1\"/></instrumentConfigurationList>\n"
        + "  <dataProcessingList count=\"1\"><dataProcessing id=\"dp\"/></dataProcessingList>\n"
        + "  <run id=\"mock_waters\" defaultInstrumentConfigurationRef=\"IC1\">\n"
        + "    <spectrumList count=\"1\" defaultDataProcessingRef=\"dp\">\n"
        + "      <spectrum index=\"0\" id=\"scan=1\" defaultArrayLength=\"2\">\n"
        + "        <cvParam cvRef=\"MS\" accession=\"MS:1000511\" name=\"ms level\" value=\"1\"/>\n"
        + "        <cvParam cvRef=\"MS\" accession=\"MS:1000130\" name=\"positive scan\"/>\n"
        + "        <scanList count=\"1\"><scan>\n"
        + "          <cvParam cvRef=\"MS\" accession=\"MS:1000016\" name=\"scan start time\" value=\"0.0\" unitCvRef=\"UO\" unitAccession=\"UO:0000010\"/>\n"
        + "        </scan></scanList>\n"
        + "        <binaryDataArrayList count=\"2\">\n"
        + "          <binaryDataArray encodedLength=\"16\">\n"
        + "            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
        + "            <cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/>\n"
        + "            <cvParam cvRef=\"MS\" accession=\"MS:1000514\" name=\"m/z array\"/>\n"
        + "            <binary>AAAAAAAAJEAAAAAAAAA0QA==</binary>\n"
        + "          </binaryDataArray>\n"
        + "          <binaryDataArray encodedLength=\"16\">\n"
        + "            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
        + "            <cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/>\n"
        + "            <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\"/>\n"
        + "            <binary>AAAAAAAA8D8AAAAAAAAAQA==</binary>\n"
        + "          </binaryDataArray>\n"
        + "        </binaryDataArrayList>\n"
        + "      </spectrum>\n"
        + "    </spectrumList>\n"
        + "  </run>\n"
        + "</mzML>\n";

    private static Path writeMockConverter(Path dir) throws IOException {
        Path script = dir.resolve("mock_masslynxraw");
        String src = ""
            + "#!/bin/sh\n"
            + "set -eu\n"
            + "input=\"\"\n"
            + "output=\"\"\n"
            + "while [ $# -gt 0 ]; do\n"
            + "    case \"$1\" in\n"
            + "        -i) input=$2; shift 2;;\n"
            + "        -o) output=$2; shift 2;;\n"
            + "        *) shift;;\n"
            + "    esac\n"
            + "done\n"
            + "if [ -z \"$input\" ] || [ -z \"$output\" ]; then\n"
            + "    echo 'usage: $0 -i <input.raw> -o <output-dir>' >&2\n"
            + "    exit 2\n"
            + "fi\n"
            + "stem=$(basename \"$input\" .raw)\n"
            + "cat > \"$output/$stem.mzML\" <<'MPGO_EOF'\n"
            + STUB_MZML
            + "MPGO_EOF\n";
        Files.writeString(script, src);
        Files.setPosixFilePermissions(script, Set.of(
            PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE,
            PosixFilePermission.OWNER_EXECUTE,
            PosixFilePermission.GROUP_READ, PosixFilePermission.GROUP_EXECUTE,
            PosixFilePermission.OTHERS_READ, PosixFilePermission.OTHERS_EXECUTE));
        return script;
    }

    @Test
    void missingBinary_raisesClearError(@TempDir Path tmp) throws IOException {
        Path raw = tmp.resolve("Sample.raw");
        Files.createDirectory(raw);
        IOException ex = assertThrows(IOException.class,
            () -> WatersMassLynxReader.read(raw.toString(),
                "/nonexistent/no-such-masslynx"));
        assertTrue(ex.getMessage().toLowerCase().contains("not found")
                || ex.getMessage().toLowerCase().contains("not executable"));
    }

    @Test
    void missingInput_raisesIOException(@TempDir Path tmp) {
        IOException ex = assertThrows(IOException.class,
            () -> WatersMassLynxReader.read(
                tmp.resolve("does-not-exist.raw").toString()));
        assertTrue(ex.getMessage().contains("not found"));
    }

    @Test
    void fileNotDirectory_rejected(@TempDir Path tmp) throws IOException {
        Path bogus = tmp.resolve("not_a_dir.raw");
        Files.writeString(bogus, "plain text");
        IOException ex = assertThrows(IOException.class,
            () -> WatersMassLynxReader.read(bogus.toString()));
        assertTrue(ex.getMessage().contains("not found"));
    }

    @Test
    void mockConverter_roundTrip(@TempDir Path tmp) throws IOException {
        Path raw = tmp.resolve("Sample_01.raw");
        Files.createDirectory(raw);
        Path mock = writeMockConverter(tmp);

        AcquisitionRun run = WatersMassLynxReader.read(
            raw.toString(), mock.toString());
        assertNotNull(run, "mock converter should produce a run");
        assertEquals(1, run.spectrumCount(), "stub mzML has 1 spectrum");
    }
}

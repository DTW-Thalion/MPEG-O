/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.protection;

import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.hdf5.Hdf5Dataset;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Cross-language {@code dek_wrapped} envelope-encryption conformance.
 *
 * <p>Proves that the dataset-level wrapped-DEK blob at
 * {@code /protection/key_info/dek_wrapped} written by ANY language
 * (Python / Java / ObjC) is correctly read <em>and unwrapped</em> by
 * Java. Combined with the Python ({@code test_dek_wrapped_xlang.py})
 * and ObjC ({@code TestDekWrappedXLang}) peers, this gives the full
 * NxN writer×reader matrix.</p>
 *
 * <p>This is the conformance test whose ABSENCE let the
 * {@code fix/dek-wrapped-xlang} bug ship: Java/ObjC used to store
 * {@code dek_wrapped} as an {@code int32}-packed, 4-byte-padded dataset
 * while Python stored the spec-compliant {@code uint8[N]} exact-length
 * blob, so a file written by one language crashed
 * ({@code ClassCastException}) or corrupted (1639→60 truncation) when
 * read by another. All three now write {@code uint8[N]}.</p>
 *
 * <p>The fixtures + committed KEK + expected DEK hex live under
 * {@code conformance/key_rotation/} and are produced by
 * {@code conformance/key_rotation/gen_fixtures.py}.</p>
 *
 * <p>Coverage: AES-256-GCM only — the Java
 * {@link KeyRotationManager} exposes no dataset-level ML-KEM read path,
 * so the PQC fixtures are covered by the Python/ObjC peers. Java reads
 * the AES fixtures written by py / java / objc.</p>
 */
class DekWrappedXLangTest {

    private record Fixture(String name, String writer, String algorithm,
                           String expectedDekHex) {}

    private static Path conformanceDir() {
        Path dir = Path.of("").toAbsolutePath();
        for (int i = 0; i < 6 && dir != null; i++) {
            Path cand = dir.resolve("conformance/key_rotation/expected.json");
            if (Files.isRegularFile(cand)) return cand.getParent();
            dir = dir.getParent();
        }
        return null;
    }

    /** Extract the string value of {@code field} starting at {@code from}. */
    private static String strAfter(String json, String field, int from) {
        String marker = "\"" + field + "\": \"";
        int idx = json.indexOf(marker, from);
        if (idx < 0) return null;
        int start = idx + marker.length();
        int end = json.indexOf("\"", start);
        return json.substring(start, end);
    }

    /** Parse the committed manifest's {@code fixtures} array without a
     *  JSON dependency (mirrors MultiRecipientXLangTest's scraping). */
    private static List<Fixture> loadFixtures(Path dir) throws Exception {
        String json = Files.readString(dir.resolve("expected.json"));
        List<Fixture> out = new ArrayList<>();
        int pos = json.indexOf("\"fixtures\"");
        assertTrue(pos >= 0, "manifest missing fixtures array");
        while (true) {
            int nameIdx = json.indexOf("\"fixture\": \"", pos);
            if (nameIdx < 0) break;
            String name = strAfter(json, "fixture", nameIdx - 1);
            String writer = strAfter(json, "writer", nameIdx);
            String alg = strAfter(json, "algorithm", nameIdx);
            String dek = strAfter(json, "expected_dek_hex", nameIdx);
            out.add(new Fixture(name, writer, alg, dek));
            pos = nameIdx + 1;
        }
        return out;
    }

    @Test
    void javaReadsCrossLanguageDekWrapped() throws Exception {
        Path dir = conformanceDir();
        org.junit.jupiter.api.Assumptions.assumeTrue(dir != null,
            "conformance/key_rotation fixtures not generated");

        byte[] kek = Files.readAllBytes(dir.resolve("kek_aes.bin"));
        assertEquals(32, kek.length);

        List<Fixture> fixtures = loadFixtures(dir);
        int aesChecked = 0;
        List<String> writersSeen = new ArrayList<>();

        for (Fixture fx : fixtures) {
            if (!"aes-256-gcm".equals(fx.algorithm())) {
                // Java has no dataset-level ML-KEM read path — skip PQC.
                continue;
            }
            Path tio = dir.resolve("fixtures").resolve(fx.name());
            assertTrue(Files.isRegularFile(tio), "missing fixture " + fx.name());

            // Guard the on-disk layout: the bug was a non-uint8 dataset.
            try (Hdf5File f = Hdf5File.openReadOnly(tio.toString());
                 Hdf5Group root = f.rootGroup();
                 Hdf5Group prot = root.openGroup("protection");
                 Hdf5Group ki = prot.openGroup("key_info");
                 Hdf5Dataset ds = ki.openDataset("dek_wrapped")) {
                assertEquals(Precision.UINT8, ds.getPrecision(),
                    fx.name() + ": dek_wrapped must be uint8 for "
                    + "cross-language reads (int32 layout corrupts them)");
                assertEquals(71L, ds.getLength(),
                    fx.name() + ": AES-GCM dek_wrapped must be exactly 71 "
                    + "bytes, unpadded");
            }

            // Unwrap via the public read path and assert the recovered DEK.
            byte[] dek;
            try (Hdf5File f = Hdf5File.openReadOnly(tio.toString());
                 Hdf5Group root = f.rootGroup()) {
                KeyRotationManager mgr = KeyRotationManager.readFrom(root, kek);
                dek = mgr.getDek();
            }
            assertEquals(fx.expectedDekHex(),
                HexFormat.of().formatHex(dek),
                fx.name() + ": Java recovered the wrong DEK from a "
                + "dek_wrapped blob written by " + fx.writer());
            aesChecked++;
            writersSeen.add(fx.writer());
        }

        assertTrue(aesChecked >= 1, "no AES fixtures were checked");
        // The universal NxN guarantee: Java must read every writer's
        // AES fixture (py/java/objc) when all toolchains generated them.
        assertTrue(writersSeen.contains("py"),
            "Python-written AES dek_wrapped not present/readable — this is "
            + "the historic crash case the fix addresses");
    }
}

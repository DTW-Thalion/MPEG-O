/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.protection;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * FD-1 Phase A-4 — cross-language conformance for the multi-recipient
 * {@code ProtectionMetadata} wire format.
 *
 * <p>The golden byte vectors live in
 * {@code conformance/multi_recipient/vectors.json} and are shared with the
 * Python and ObjC suites. This test reconstructs each vector's inputs and
 * asserts that Java's encoder produces the golden bytes (and its decoder
 * recovers the recipient list). Because every language asserts against the
 * <em>same</em> committed hex, byte-parity across Python / Java / ObjC is
 * transitive.
 *
 * <p>The recipient inputs are mirrored in code here; the expected
 * {@code recipient_block_hex} / {@code body_hex} are read from the JSON, so
 * any drift between the generator inputs and this test fails the assertion.
 */
class MultiRecipientXLangTest {

    private static byte[] fill(int n, int v) {
        byte[] b = new byte[n];
        Arrays.fill(b, (byte) v);
        return b;
    }

    // Mirror gen_vectors.py's fillers.
    private static final byte[] SERVER = fill(48, 0x11);
    private static final byte[] RESEARCHER = fill(1568, 0x22);
    private static final byte[] AUDITOR = fill(512, 0x44);
    private static final byte[] PQC = fill(1568, 0x33);

    /** One golden vector: primary fields + the additional recipient list. */
    private record Vec(String name, String cipherSuite, String kek,
                       byte[] wrapped,
                       List<EncryptedTransport.Recipient> additional,
                       String serverKekId) {}

    private static final String KID = "server:kek-proj-adni";

    private static List<Vec> vectors() {
        return List.of(
            new Vec("prot_single_byok", "aes-256-gcm", "none",
                    new byte[0], List.of(), null),
            new Vec("prot_single_envelope", "aes-256-gcm", "aes-256-gcm",
                    SERVER, List.of(), null),
            new Vec("prot_single_pqc", "aes-256-gcm", "ml-kem-1024",
                    PQC, List.of(), null),
            new Vec("prot_multi_server_researcher", "aes-256-gcm", "aes-256-gcm",
                    SERVER, List.of(
                        new EncryptedTransport.Recipient(
                            "researcher", "ml-kem-1024", RESEARCHER)), null),
            new Vec("prot_multi_three", "aes-256-gcm", "aes-256-gcm",
                    SERVER, List.of(
                        new EncryptedTransport.Recipient(
                            "researcher", "ml-kem-1024", RESEARCHER),
                        new EncryptedTransport.Recipient(
                            "auditor", "rsa-4096-oaep", AUDITOR)), null),
            new Vec("prot_server_kek_id_single", "aes-256-gcm", "aes-256-gcm",
                    SERVER, List.of(), KID),
            new Vec("prot_server_kek_id_multi", "aes-256-gcm", "aes-256-gcm",
                    SERVER, List.of(
                        new EncryptedTransport.Recipient(
                            "researcher", "ml-kem-1024", RESEARCHER)), KID)
        );
    }

    // ── golden file access ───────────────────────────────────────────

    private static Path vectorsPath() {
        // mvn runs from java/; the repo root is its parent. Walk up to be
        // robust against the working directory.
        Path dir = Path.of("").toAbsolutePath();
        for (int i = 0; i < 6 && dir != null; i++) {
            Path cand = dir.resolve("conformance/multi_recipient/vectors.json");
            if (Files.isRegularFile(cand)) return cand;
            dir = dir.getParent();
        }
        throw new IllegalStateException(
            "vectors.json not found from " + Path.of("").toAbsolutePath());
    }

    private static String json;

    private static String loadJson() {
        if (json == null) {
            try {
                json = Files.readString(vectorsPath());
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }
        return json;
    }

    /** Extract a string field's value that appears after the given vector
     *  name in the pretty-printed JSON. */
    private static String hexField(String vectorName, String field) {
        String j = loadJson();
        int nameIdx = j.indexOf("\"name\": \"" + vectorName + "\"");
        assertTrue(nameIdx >= 0, "vector not in golden: " + vectorName);
        String marker = "\"" + field + "\": \"";
        int idx = j.indexOf(marker, nameIdx);
        assertTrue(idx >= 0, "field not found: " + field);
        int start = idx + marker.length();
        int end = j.indexOf("\"", start);
        return j.substring(start, end);
    }

    private static String toHex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(String.format("%02x", x & 0xFF));
        return sb.toString();
    }

    private static byte[] fromHex(String h) {
        int n = h.length() / 2;
        byte[] b = new byte[n];
        for (int i = 0; i < n; i++) {
            b[i] = (byte) Integer.parseInt(h.substring(2 * i, 2 * i + 2), 16);
        }
        return b;
    }

    // ── assertions ───────────────────────────────────────────────────

    @Test
    void recipientBlockEncodesToGolden() {
        for (Vec v : vectors()) {
            String golden = hexField(v.name(), "recipient_block_hex");
            assertEquals(golden,
                toHex(EncryptedTransport.encodeRecipientBlock(v.additional())),
                v.name() + ": recipient block bytes");
        }
    }

    @Test
    void recipientBlockRoundTrips() {
        for (Vec v : vectors()) {
            byte[] block = fromHex(hexField(v.name(), "recipient_block_hex"));
            List<EncryptedTransport.Recipient> got =
                EncryptedTransport.decodeRecipientBlockBytes(block);
            assertEquals(v.additional().size(), got.size(), v.name() + ": count");
            for (int i = 0; i < got.size(); i++) {
                assertEquals(v.additional().get(i).recipientId(),
                             got.get(i).recipientId());
                assertEquals(v.additional().get(i).kekAlgorithm(),
                             got.get(i).kekAlgorithm());
                assertArrayEquals(v.additional().get(i).wrappedDek(),
                                  got.get(i).wrappedDek());
            }
        }
    }

    @Test
    void fullBodyEncodesToGolden() {
        for (Vec v : vectors()) {
            String golden = hexField(v.name(), "body_hex");
            byte[] body = EncryptedTransport.encodeProtection(
                v.cipherSuite(), v.kek(), v.wrapped(), v.additional(),
                v.serverKekId());
            assertEquals(golden, toHex(body), v.name() + ": full body bytes");
        }
    }

    @Test
    void fullBodyDecodesToRecipientList() {
        for (Vec v : vectors()) {
            byte[] body = fromHex(hexField(v.name(), "body_hex"));
            EncryptedTransport.ProtectionMeta pm =
                EncryptedTransport.parseProtection(body);
            // FD-1 C-2a: server_kek_id round-trips through the body.
            assertEquals(v.serverKekId(), pm.serverKekId(),
                         v.name() + ": server_kek_id");
            // primary
            assertEquals(v.kek(), pm.kekAlgorithm(), v.name() + ": primary kek");
            assertArrayEquals(v.wrapped(), pm.wrappedDek(),
                              v.name() + ": primary wrapped");
            // additional
            List<EncryptedTransport.Recipient> add = pm.additionalRecipients();
            assertEquals(v.additional().size(), add.size(), v.name());
            for (int i = 0; i < add.size(); i++) {
                assertEquals(v.additional().get(i).recipientId(),
                             add.get(i).recipientId());
                assertArrayEquals(v.additional().get(i).wrappedDek(),
                                  add.get(i).wrappedDek());
            }
        }
    }
}

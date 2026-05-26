/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.SpectralDataset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * v0.11 Task 1.5 (transport-spec §4.23): exercise the
 * {@code ENCRYPTION_ALGORITHM} (0x1B) packet on
 * {@link TransportWriter} + {@link TransportReader}. Wire layout:
 * {@code uint16 algorithm_length + bytes algorithm_utf8[length]}.
 * All multi-byte integers LITTLE-ENDIAN (spec §1.7).
 */
class TransportEncryptionAlgorithmTest {

    /** Writer's low-level helper emits a single 0x1B packet whose
     *  payload matches §4.23 exactly. */
    @Test
    void writeEncryptionAlgorithm_emits_single_0x1B_packet() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (TransportWriter w = new TransportWriter(out)) {
            w.writeStreamHeader("1.2", "enc-test", "isa", List.of(), 0);
            w.writeEncryptionAlgorithm("aes-256-gcm");
            w.writeEndOfStream();
        }

        TransportReader r = new TransportReader(out.toByteArray());
        var records = r.recordsForTest();
        assertEquals(3, records.size(),
            "expected StreamHeader + EncryptionAlgorithm + EndOfStream");
        assertEquals(PacketType.ENCRYPTION_ALGORITHM,
            records.get(1).header.packetType);

        ByteBuffer bb = ByteBuffer.wrap(records.get(1).payload)
            .order(ByteOrder.LITTLE_ENDIAN);
        int len = bb.getShort() & 0xFFFF;
        byte[] algoBytes = new byte[len];
        bb.get(algoBytes);
        assertEquals("aes-256-gcm",
            new String(algoBytes, StandardCharsets.UTF_8));
        assertFalse(bb.hasRemaining(),
            "payload must contain only length + algorithm bytes");
    }

    /** writeDataset on an encrypted .tio emits exactly one
     *  ENCRYPTION_ALGORITHM packet (in the v0.11 prelude, before any
     *  reference groups per §5.4 ordering) AND sets the v0.11 feature
     *  flag in the StreamHeader. */
    @Test
    void writeDataset_emits_encryption_algorithm_when_encrypted(@TempDir Path tmp)
            throws Exception {
        Path src = buildEncryptedAlgorithmOnly(tmp.resolve("enc.tio"));
        Path tis = tmp.resolve("enc.tis");

        try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
            assertTrue(ds.isEncrypted(),
                "fixture precondition: dataset must be encrypted");
            assertEquals("aes-256-gcm", ds.encryptedAlgorithm());
            try (OutputStream out = Files.newOutputStream(tis);
                 TransportWriter w = new TransportWriter(out)) {
                w.writeDataset(ds);
            }
        }

        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        var records = r.recordsForTest();
        // StreamHeader features must include transport_v0_11.
        String shFeatures = new String(records.get(0).payload,
                StandardCharsets.UTF_8);
        assertTrue(shFeatures.contains("transport_v0_11"),
            "StreamHeader must carry transport_v0_11 feature flag");

        int encCount = 0;
        for (var rec : records) {
            if (rec.header.packetType == PacketType.ENCRYPTION_ALGORITHM) {
                encCount++;
                ByteBuffer bb = ByteBuffer.wrap(rec.payload)
                    .order(ByteOrder.LITTLE_ENDIAN);
                int len = bb.getShort() & 0xFFFF;
                byte[] algoBytes = new byte[len];
                bb.get(algoBytes);
                assertEquals("aes-256-gcm",
                    new String(algoBytes, StandardCharsets.UTF_8));
            }
        }
        assertEquals(1, encCount,
            "writeDataset on encrypted .tio must emit exactly one "
            + "ENCRYPTION_ALGORITHM packet");
    }

    /** writeDataset on a NON-encrypted .tio emits NO 0x1B packet and
     *  does not flip the v0.11 feature flag on that basis. */
    @Test
    void writeDataset_no_packet_when_not_encrypted(@TempDir Path tmp)
            throws Exception {
        Path src = tmp.resolve("plain.tio");
        try (SpectralDataset ignore = SpectralDataset.create(
                src.toString(), "plain", "",
                List.of(), List.of(), List.of(), List.of())) {
            // empty plaintext dataset.
        }
        Path tis = tmp.resolve("plain.tis");
        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            assertFalse(ds.isEncrypted(),
                "fixture precondition: dataset must not be encrypted");
            w.writeDataset(ds);
        }

        TransportReader r = new TransportReader(Files.readAllBytes(tis));
        var records = r.recordsForTest();
        for (var rec : records) {
            assertNotEquals(PacketType.ENCRYPTION_ALGORITHM,
                rec.header.packetType,
                "non-encrypted dataset must not emit ENCRYPTION_ALGORITHM");
        }
    }

    /** End-to-end round-trip: writer emits ENCRYPTION_ALGORITHM, reader
     *  materialises it, the resulting on-disk .tio reports the same
     *  algorithm and {@code isEncrypted() == true}. */
    @Test
    void encryption_algorithm_round_trips_via_writeDataset_materializeTo(
            @TempDir Path tmp) throws Exception {
        Path src = buildEncryptedAlgorithmOnly(tmp.resolve("src.tio"));
        Path tis = tmp.resolve("src.tis");
        Path rt  = tmp.resolve("rt.tio");

        try (SpectralDataset ds = SpectralDataset.open(src.toString());
             OutputStream out = Files.newOutputStream(tis);
             TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(ds);
        }

        try (TransportReader r = new TransportReader(Files.readAllBytes(tis));
             SpectralDataset materialised = r.materializeTo(rt.toString())) {
        }

        try (SpectralDataset b = SpectralDataset.open(rt.toString())) {
            assertTrue(b.isEncrypted(),
                "round-tripped dataset must report isEncrypted() == true");
            assertEquals("aes-256-gcm", b.encryptedAlgorithm(),
                "round-tripped algorithm string must match source");
        }
    }

    /** Build a minimal .tio whose root carries @encrypted = "aes-256-gcm"
     *  via the provider-level attribute setter. Mirrors the
     *  {@link FixtureBuilder} pattern locally to keep this test
     *  self-contained until the encrypted-algorithm fixture becomes
     *  broadly useful. */
    private static Path buildEncryptedAlgorithmOnly(Path target) throws Exception {
        try (SpectralDataset ds = SpectralDataset.create(
                target.toString(), "encryption_only", "",
                List.of(), List.of(), List.of(), List.of())) {
            // Set the root @encrypted attribute through the open
            // provider so the on-disk file carries it.
            ds.provider().rootGroup().setAttribute("encrypted", "aes-256-gcm");
        }
        return target;
    }
}

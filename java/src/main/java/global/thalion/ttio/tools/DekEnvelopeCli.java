/*
 * TTI-O Java Implementation — dataset-level envelope-encryption
 * dek_wrapped cross-language conformance CLI.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;
import global.thalion.ttio.protection.KeyRotationManager;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HexFormat;

/**
 * Cross-language conformance CLI for the dataset-level
 * envelope-encryption {@code /protection/key_info/dek_wrapped} dataset.
 *
 * <p>This proves a {@code dek_wrapped} blob written by one language is
 * read <em>and unwrapped</em> by the others — guarding the bug fixed on
 * {@code fix/dek-wrapped-xlang} where Java/ObjC stored {@code dek_wrapped}
 * as an {@code int32}-padded dataset while Python stored the
 * spec-compliant {@code uint8[N]} exact-length blob, corrupting
 * cross-language reads. All three now write {@code uint8[N]}.</p>
 *
 * <p>Mirrors Python {@code ttio.tools.dek_envelope_cli} and Objective-C
 * {@code TtioDekEnvelope}.</p>
 *
 * <p>Usage:
 * <pre>
 *   java -cp ... DekEnvelopeCli wrap   out.tio kek-file [--algorithm aes-256-gcm]
 *   java -cp ... DekEnvelopeCli unwrap in.tio  kek-file [--algorithm aes-256-gcm]
 * </pre>
 *
 * <p>{@code wrap} generates a fresh random DEK (the production path),
 * wraps it under the 32-byte KEK read from {@code kek-file}, persists
 * {@code key_info}, and prints the plaintext DEK as lowercase hex.
 * {@code unwrap} opens the file, unwraps with the KEK, and prints the
 * recovered DEK hex. Cross-language equality of the recovered DEK
 * against the writer's reported DEK proves the on-disk layout is
 * interoperable.</p>
 *
 * <p>The Java {@link KeyRotationManager} supports only the
 * {@code aes-256-gcm} (71-byte) wrap at the dataset level; ML-KEM
 * envelope encryption is not exposed here, so the PQC matrix cells are
 * covered by Python/ObjC only.</p>
 */
public final class DekEnvelopeCli {

    private DekEnvelopeCli() {}

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println(
                "usage: DekEnvelopeCli (wrap|unwrap) <file.tio> <kek-file> "
                + "[--algorithm aes-256-gcm]");
            System.exit(2);
        }
        String cmd = args[0];
        String file = args[1];
        String kekFile = args[2];
        String algorithm = "aes-256-gcm";
        for (int i = 3; i < args.length; i++) {
            if ("--algorithm".equals(args[i]) && i + 1 < args.length) {
                algorithm = args[++i];
            }
        }
        if (!"aes-256-gcm".equals(algorithm)) {
            System.err.println(
                "DekEnvelopeCli: Java supports only aes-256-gcm dataset-level "
                + "envelope encryption (got " + algorithm + ")");
            System.exit(3);
        }

        byte[] kek = Files.readAllBytes(Path.of(kekFile));
        if (kek.length != 32) {
            System.err.println(
                "aes-256-gcm KEK file must be 32 bytes, got " + kek.length);
            System.exit(2);
        }

        if ("wrap".equals(cmd)) {
            KeyRotationManager mgr = new KeyRotationManager();
            mgr.enableEnvelopeEncryption(kek, "kek-xlang");
            try (Hdf5File f = Hdf5File.create(file);
                 Hdf5Group root = f.rootGroup()) {
                mgr.writeTo(root);
            }
            System.out.println(HexFormat.of().formatHex(mgr.getDek()));
        } else if ("unwrap".equals(cmd)) {
            byte[] dek;
            try (Hdf5File f = Hdf5File.openReadOnly(file);
                 Hdf5Group root = f.rootGroup()) {
                KeyRotationManager mgr = KeyRotationManager.readFrom(root, kek);
                dek = mgr.getDek();
            }
            System.out.println(HexFormat.of().formatHex(dek));
        } else {
            System.err.println("unknown command: " + cmd);
            System.exit(2);
        }
    }
}

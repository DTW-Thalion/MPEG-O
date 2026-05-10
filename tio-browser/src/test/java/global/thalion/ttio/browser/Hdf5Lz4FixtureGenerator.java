/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser;

import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.Enums.Precision;
import global.thalion.ttio.hdf5.Hdf5Dataset;
import global.thalion.ttio.hdf5.Hdf5File;
import global.thalion.ttio.hdf5.Hdf5Group;

/**
 * One-off generator for {@code src/test/resources/ttio/lz4_compressed.tio}.
 * Run via {@code mvn exec:java} (or the bare {@code java -cp ...} form
 * shown below) after Phase D wires bundled HDF5 + LZ4 natives. Re-run
 * only when the fixture schema needs to change.
 *
 * <p>Generates a small (4 KiB payload) HDF5 dataset compressed with the
 * LZ4 filter (filter id 32004), so {@link Hdf5Lz4PluginTest} can verify
 * the bundled LZ4 plugin handles round-trip read.
 *
 * <p>The payload is the byte sequence {@code (byte) (i &amp; 0xff)} for
 * {@code i in [0, 4096)}, written as a UINT8 1-D dataset {@code lz4_payload}
 * inside a {@code study} group. Chunk size is 1024 bytes.
 *
 * <h2>Local invocation</h2>
 * <pre>{@code
 * # Requires libh5lz4.so on HDF5_PLUGIN_PATH. The python hdf5plugin
 * # package ships one that works with HDF5 1.14:
 * export HDF5_PLUGIN_PATH=$(python3 -c \
 *     'import hdf5plugin; print(hdf5plugin.PLUGIN_PATH)')
 * cd tio-browser
 * mvn -B -DskipTests test-compile
 * java -cp "$(mvn -q dependency:build-classpath \
 *               -Dmdep.outputFile=/dev/stdout | tail -1):\
 *target/classes:target/test-classes" \
 *   global.thalion.ttio.browser.Hdf5Lz4FixtureGenerator
 * }</pre>
 *
 * <p>In CI, Phase D wires the LZ4 plugin into the shaded JAR, so
 * {@link Hdf5NativeLoader#ensureLoaded()} suffices.
 */
public final class Hdf5Lz4FixtureGenerator {

    /** Total bytes in the generated payload. */
    public static final int PAYLOAD_LEN = 4096;
    /** Chunk size used when creating the LZ4-compressed dataset. */
    public static final int CHUNK_SIZE = 1024;

    public static void main(String[] args) {
        // Try the bundled-natives path first (works in CI after Phase D).
        // Locally, this throws because no /native/<platform>/hdf5/* lives
        // on the classpath; fall back to the system HDF5 + an externally
        // configured HDF5_PLUGIN_PATH.
        try {
            Hdf5NativeLoader.ensureLoaded();
        } catch (RuntimeException e) {
            // Bundled natives not available — use system HDF5. This is
            // the dev path; CI takes the ensureLoaded() branch above.
            System.err.println("Hdf5NativeLoader.ensureLoaded() not usable here ("
                + e.getMessage() + "); falling back to system HDF5. "
                + "Set HDF5_PLUGIN_PATH to a directory containing libh5lz4.so.");
        }

        String out = args.length > 0
            ? args[0]
            : "src/test/resources/ttio/lz4_compressed.tio";
        byte[] payload = new byte[PAYLOAD_LEN];
        for (int i = 0; i < payload.length; i++) {
            payload[i] = (byte) (i & 0xff);
        }
        try (Hdf5File f = Hdf5File.create(out);
             Hdf5Group root = f.rootGroup();
             Hdf5Group g = root.createGroup("study")) {
            Hdf5Dataset ds = g.createDataset("lz4_payload",
                    Precision.UINT8, payload.length, CHUNK_SIZE,
                    Compression.LZ4, 0);
            try {
                ds.writeData(payload);
            } finally {
                ds.close();
            }
        }
        System.out.println("Wrote " + out);
    }

    private Hdf5Lz4FixtureGenerator() {}
}

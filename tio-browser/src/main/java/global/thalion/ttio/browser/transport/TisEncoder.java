/*
 * tio-browser — TTI-O dataset browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.transport;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.transport.TransportWriter;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Encodes a local {@code .tio} file to a temporary {@code .tis} transport
 * byte stream suitable for uploading to a transport server.
 *
 * <p>The produced stream contains exactly one dataset and ends with an
 * {@code END_OF_STREAM} packet. The caller is responsible for deleting the
 * tempfile when it is no longer needed.</p>
 *
 * <p>Internally, {@link TransportWriter#writeDataset} handles the full
 * stream framing (STREAM_HEADER, dataset headers, access units,
 * END_OF_DATASET, and END_OF_STREAM).</p>
 */
public final class TisEncoder {

    private TisEncoder() {}

    /**
     * Encode the dataset at {@code tioPath} into a fresh temporary
     * {@code .tis} file and return that file's {@link Path}.
     *
     * @param tioPath   absolute or relative path to the source {@code .tio}
     * @param checksum  when {@code true}, emit a CRC-32C suffix on every packet
     * @return path of the populated temp file (caller must delete when done)
     * @throws IOException if the source cannot be opened or the temp file
     *                     cannot be written
     */
    public static Path encodeToTempFile(String tioPath, boolean checksum)
            throws IOException {
        Path tmp = Files.createTempFile("upload-", ".tis");
        try (SpectralDataset ds = SpectralDataset.open(tioPath);
             OutputStream out = Files.newOutputStream(tmp);
             TransportWriter w = new TransportWriter(out)) {
            w.setUseChecksum(checksum);
            // writeDataset emits STREAM_HEADER, all dataset packets,
            // and END_OF_STREAM — no extra framing calls needed.
            w.writeDataset(ds);
        }
        return tmp;
    }
}

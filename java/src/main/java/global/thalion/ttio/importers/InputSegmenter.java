// SPDX-License-Identifier: Apache-2.0
package global.thalion.ttio.importers;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;

/** Classifies an import input for the parallel producers: seekable
 *  plain files shard; everything else (gzip streams, pipes) is
 *  pipeline mode. The caller never chooses.
 *
 *  <p>Cross-language equivalent: ObjC {@code TTIOInputSegmenter}.</p> */
public final class InputSegmenter {
    private InputSegmenter() { }

    public enum Mode { PIPELINE, SHARD }

    /** Shard iff {@code path} is a regular file that does not start
     *  with the gzip magic. */
    public static Mode modeFor(Path path) {
        try {
            if (!Files.isRegularFile(path)) return Mode.PIPELINE;
            try (InputStream in = Files.newInputStream(path)) {
                int a = in.read(), b = in.read();
                if (a == 0x1f && b == 0x8b) return Mode.PIPELINE;
            }
            return Mode.SHARD;
        } catch (IOException e) {
            return Mode.PIPELINE;
        }
    }
}

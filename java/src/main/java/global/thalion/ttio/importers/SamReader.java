/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.importers;

import java.nio.file.Path;

/**
 * Convenience subclass of {@link BamReader} for SAM input.
 *
 * <p>Functionally identical to {@link BamReader} (samtools auto-detects
 * SAM vs BAM from magic bytes); kept as a separate class for API
 * clarity in callsites that explicitly handle SAM text input.</p>
 *
 * <p><b>Cross-language equivalents:</b> Python
 * {@code ttio.importers.sam.SamReader}, Objective-C
 * {@code TTIOSamReader}.</p>
 *
 * (M87)
 */
public class SamReader extends BamReader {
    public SamReader(Path path) { super(path); }
}

/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_SAM_READER_H
#define TTIO_SAM_READER_H

#import "TTIOBamReader.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Convenience wrapper for SAM input.
 *
 * Functionally identical to :class:`TTIOBamReader` (samtools auto-
 * detects SAM vs BAM from magic bytes); kept as a separate class for
 * API clarity in callsites that explicitly handle SAM text input.
 *
 * Cross-language equivalents:
 *   Python: ttio.importers.sam.SamReader
 *   Java:   global.thalion.ttio.importers.SamReader
 */
@interface TTIOSamReader : TTIOBamReader
@end

NS_ASSUME_NONNULL_END

#endif  /* TTIO_SAM_READER_H */

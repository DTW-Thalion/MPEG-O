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
 * <heading>TTIOSamReader</heading>
 *
 * <p><em>Inherits From:</em> TTIOBamReader : NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOSamReader.h</p>
 *
 * <p>Convenience wrapper for SAM (Sequence Alignment/Map) text input.
 * Functionally identical to <code>TTIOBamReader</code> &mdash;
 * <code>samtools</code> auto-detects SAM vs BAM from magic bytes
 * &mdash; but kept as a separate class for API clarity at call sites
 * that explicitly handle SAM text input.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.sam.SamReader</code><br/>
 * Java: <code>global.thalion.ttio.importers.SamReader</code></p>
 */
@interface TTIOSamReader : TTIOBamReader
@end

NS_ASSUME_NONNULL_END

#endif  /* TTIO_SAM_READER_H */

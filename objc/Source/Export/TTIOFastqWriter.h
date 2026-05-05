/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_FASTQ_WRITER_H
#define TTIO_FASTQ_WRITER_H

#import <Foundation/Foundation.h>

@class TTIOWrittenGenomicRun;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIOFastqWriter.h</p>
 *
 * <p>FASTQ exporter. Each read becomes four lines: header
 * (<code>@name</code>), sequence, separator (<code>+</code>), and
 * qualities. Internal <code>0xFF</code> "qualities unknown"
 * sentinels are mapped to Phred 0 (<code>!</code>) on output.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.fastq.FastqWriter</code><br/>
 * Java: <code>global.thalion.ttio.exporters.FastqWriter</code></p>
 */
@interface TTIOFastqWriter : NSObject

/**
 * @param run         Source run.
 * @param path        Destination path.
 * @param gzipOutput  <code>0</code> = derive from <code>.gz</code>
 *                    suffix; <code>1</code> = force on; <code>-1</code>
 *                    = force off.
 * @param phredOffset <code>33</code> (default) or <code>64</code>.
 * @param error       Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
+ (BOOL)writeRun:(TTIOWrittenGenomicRun *)run
          toPath:(NSString *)path
      gzipOutput:(int)gzipOutput
     phredOffset:(uint8_t)phredOffset
           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif

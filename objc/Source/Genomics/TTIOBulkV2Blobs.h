/*
 * TTIOBulkV2Blobs.h
 * TTI-O Objective-C Implementation
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_BULK_V2_BLOBS_H
#define TTIO_BULK_V2_BLOBS_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Genomics/TTIOBulkV2Blobs.h</p>
 *
 * <p>Phase 2c-T (v1.0): verbatim v2 codec blobs for direct on-disk
 * write. Set on a <code>TTIOWrittenGenomicRun</code> to bypass the
 * v2 codec encode step in the writer and write the blob bytes
 * directly to the matching HDF5 paths. Used by the transport
 * bulk-mode receiver (see <code>docs/transport-spec.md</code>
 * §6.4).</p>
 *
 * <p>Each field is independently optional. When
 * <code>mateInfoBlob</code> is non-nil, <code>mateInfoChromNames</code>
 * MUST also be supplied. <code>refDiffBlob</code> requires
 * <code>refDiffReferenceUri</code> which the writer validates against
 * the run's <code>referenceUri</code>.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.written_genomic_run.BulkV2Blobs</code><br/>
 * Java: <code>global.thalion.ttio.genomics.BulkV2Blobs</code></p>
 */
@interface TTIOBulkV2Blobs : NSObject

@property (nonatomic, copy, nullable) NSData *mateInfoBlob;
@property (nonatomic, copy, nullable) NSArray<NSString *> *mateInfoChromNames;
@property (nonatomic, copy, nullable) NSData *nameTokBlob;
@property (nonatomic, copy, nullable) NSData *refDiffBlob;
@property (nonatomic, copy, nullable) NSString *refDiffReferenceUri;

@end

NS_ASSUME_NONNULL_END

#endif

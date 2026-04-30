/*
 * TTIOReferenceResolver.h — reference chromosome resolution for M93 REF_DIFF.
 *
 * Lookup chain (Q5c = hard error):
 *
 *   embedded /study/references/<uri>/ in the open .tio file
 *      -> external FASTA at REF_PATH env var (or explicit
 *         externalReferencePath:) -> NSError out-param.
 *
 * Cross-language equivalents:
 *   Python: ttio.genomic.reference_resolver.ReferenceResolver
 *   Java:   global.thalion.ttio.codecs.ReferenceResolver
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#ifndef TTIO_REFERENCE_RESOLVER_H
#define TTIO_REFERENCE_RESOLVER_H

#import <Foundation/Foundation.h>

@class TTIOHDF5Group;
@class TTIOHDF5File;

NS_ASSUME_NONNULL_BEGIN

extern NSString * const TTIORefMissingErrorDomain;

/**
 * Resolves a reference chromosome sequence for REF_DIFF decode.
 *
 * Embed lookup is via the open HDF5 root group (the resolver walks
 * /study/references/<uri>/chromosomes/<chrom>/data). External fallback
 * reads a FASTA file (REF_PATH env var or the explicit constructor
 * arg). MD5 mismatches at either source raise NSError under
 * TTIORefMissingErrorDomain — partial decodes are not allowed.
 */
@interface TTIOReferenceResolver : NSObject

/** Initialize against an open HDF5 root group; embedded refs live at
 *  ``/study/references/<uri>/``. The external path may be nil. */
- (instancetype)initWithRootGroup:(TTIOHDF5Group *)rootGroup
          externalReferencePath:(nullable NSString *)externalReferencePath;

/** Resolve @p uri / @p chromosome to its full uppercase ACGTN bytes.
 *  Verifies the embedded MD5 (or externally-computed MD5) against
 *  @p expectedMD5. Returns nil and sets *error on any failure. */
- (nullable NSData *)resolveURI:(NSString *)uri
                    expectedMD5:(NSData *)expectedMD5
                     chromosome:(NSString *)chromosome
                          error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_REFERENCE_RESOLVER_H */

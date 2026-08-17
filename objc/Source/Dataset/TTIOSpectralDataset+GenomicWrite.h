/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "Providers/TTIOStorageProtocols.h"

@class TTIOWrittenGenomicRun;
@class TTIOGenomicWriteContext;

NS_ASSUME_NONNULL_BEGIN

/**
 * Storage-protocol genomic writer entry points shared by the
 * whole-channel write path and the blocks_v1 block encoder.
 */
@interface TTIOSpectralDataset (GenomicWriteInternal)

/** Write one /study/genomic_runs/<name>/ subtree through the storage
 *  protocol; ctx carries the state a blocks_v1 writer shares across
 *  blocks (+[TTIOGenomicWriteContext none] for a whole-channel run). */
+ (BOOL)writeGenomicRunStorage:(TTIOWrittenGenomicRun *)run
                        toGroup:(id<TTIOStorageGroup>)parent
                           name:(NSString *)name
                        context:(TTIOGenomicWriteContext *)ctx
                          error:(NSError **)error;

/** Embed each run's reference (by reference_uri) once at
 *  /study/references/<uri>/ through the storage protocol. */
+ (BOOL)embedReferencesForRuns:(NSArray<TTIOWrittenGenomicRun *> *)runs
                       inStudy:(id<TTIOStorageGroup>)study
                         error:(NSError **)error;

/** MD5 over the run's reference chromosomes in sorted-name order
 *  (empty when the run has none). */
+ (NSData *)referenceMD5ForRun:(TTIOWrittenGenomicRun *)run;

@end

NS_ASSUME_NONNULL_END

/*
 * TTIOAccessorSpec.h — Task 3.10 of transport-spec v0.11.
 *
 * Enumerates every first-class accessor on TTIOSpectralDataset that
 * is covered by v0.11's transport-spec round-trip. Each entry pairs
 * a fixture builder with a content-equality assertion scoped to that
 * one accessor.
 *
 * ObjC has no parameterised XCTest; this file provides a single
 * array of opaque records walked by TestAccessorMatrixConformance.m
 * and TestCoverageGapWatchdog.m.
 *
 * Cross-language equivalents:
 *   Java   global.thalion.ttio.transport.AccessorSpec  (commit 46c26587)
 *   Python python/tests/_v0_11_accessor_spec.py
 *
 * Stage 1 (Task 3.10): REFERENCES, MS_RUNS, GENOMIC_RUNS, IMAGE,
 * IDENTIFICATIONS, QUANTIFICATIONS, DATASET_PROVENANCE,
 * ENCRYPTION_ALGORITHM. SUBJECTS + SAMPLES are deferred until they
 * exist as first-class entities on TTIOSpectralDataset; the v0.11
 * spec mentions them but the data model still surfaces them only as
 * server-side cohort predicates.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef TTIO_ACCESSOR_SPEC_H
#define TTIO_ACCESSOR_SPEC_H

#import <Foundation/Foundation.h>

@class TTIOSpectralDataset;

NS_ASSUME_NONNULL_BEGIN

/** Block that writes a fresh .tio at `path` populated with exactly
 *  one first-class accessor's content. Returns YES on success. */
typedef BOOL (^TTIOAccessorBuildBlock)(NSString *path,
                                         NSError * _Nullable * _Nullable error);

/** Block that asserts `a` and `b` are content-equal for the one
 *  accessor this spec covers. Returns nil on equality; otherwise a
 *  human-readable mismatch reason. */
typedef NSString * _Nullable (^TTIOAccessorAssertBlock)(TTIOSpectralDataset *a,
                                                         TTIOSpectralDataset *b);

/** One row of the conformance matrix. */
@interface TTIOAccessorSpec : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) TTIOAccessorBuildBlock build;
@property (nonatomic, readonly, copy) TTIOAccessorAssertBlock assertEqual;

- (instancetype)initWithName:(NSString *)name
                        build:(TTIOAccessorBuildBlock)build
                  assertEqual:(TTIOAccessorAssertBlock)assertEqual;
@end

/** Returns the canonical list of accessor specs in stable order.
 *  Walked by the conformance + watchdog tests. */
NSArray<TTIOAccessorSpec *> *TTIOAccessorSpecsAll(void);

NS_ASSUME_NONNULL_END

#endif

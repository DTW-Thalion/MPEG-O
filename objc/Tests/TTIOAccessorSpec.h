/*
 * TTIOAccessorSpec.h — Task 3.10 + Task 5.6 of transport-spec v0.11.
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
 * ENCRYPTION_ALGORITHM.
 *
 * Stage 5 (Task 5.6, Deferral 1): MS_IMAGE_PROCESSED, RAMAN_IMAGE,
 * IR_IMAGE. MS_IMAGE_PROCESSED supplies a custom `encodeBlock` that
 * emits the §5.4 prelude with -writeImageProcessed: in place of
 * -writeImage: (opt-in sparse wire mode). Raman + IR integrate via
 * the §5.4.5 prelude image block and inherit the default encode.
 *
 * Stage 6 (Task 6.6, Deferral 2): SUBJECTS, SAMPLES. Both flow through
 * the default -writeDataset: path; the §5.4.3 prelude emits
 * SUBJECT_METADATA (0x19) before SAMPLE_METADATA (0x1A) when present.
 * Comparators walk the -subjects / -samples lists element-wise and
 * compare every TTIOSubject / TTIOSample field including the
 * attributes dict.
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

/** Stage 5 (Task 5.6) — optional block that overrides the default
 *  -writeDataset: encode step. Writes from `source` into a freshly
 *  opened TransportWriter at `outputPath`. Returns YES on success.
 *  When nil, the conformance test opens a TransportWriter at
 *  `outputPath` and calls -writeDataset:source:. */
typedef BOOL (^TTIOAccessorEncodeBlock)(TTIOSpectralDataset *source,
                                          NSString *outputPath,
                                          NSError * _Nullable * _Nullable error);

/** One row of the conformance matrix. */
@interface TTIOAccessorSpec : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) TTIOAccessorBuildBlock build;
@property (nonatomic, readonly, copy) TTIOAccessorAssertBlock assertEqual;
/** Optional Stage 5 / Task 5.6 encode override (e.g. processed-mode
 *  IMAGE wire shape). Nil for accessors that use the default
 *  -writeDataset: path. */
@property (nonatomic, readonly, copy, nullable) TTIOAccessorEncodeBlock encodeBlock;

- (instancetype)initWithName:(NSString *)name
                        build:(TTIOAccessorBuildBlock)build
                  assertEqual:(TTIOAccessorAssertBlock)assertEqual;

/** Designated initialiser with optional Stage 5 encode override. */
- (instancetype)initWithName:(NSString *)name
                        build:(TTIOAccessorBuildBlock)build
                  assertEqual:(TTIOAccessorAssertBlock)assertEqual
                  encodeBlock:(nullable TTIOAccessorEncodeBlock)encodeBlock;
@end

/** Returns the canonical list of accessor specs in stable order.
 *  Walked by the conformance + watchdog tests. */
NSArray<TTIOAccessorSpec *> *TTIOAccessorSpecsAll(void);

NS_ASSUME_NONNULL_END

#endif

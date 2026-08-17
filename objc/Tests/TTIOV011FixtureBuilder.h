/*
 * TTIOV011FixtureBuilder.h — Task 3.10 of transport-spec v0.11.
 *
 * Test-only fixture builder. Each +build... class method writes a
 * fresh .tio at the given path and returns YES on success. Used by
 * the v0.11 transport-spec conformance suite
 * (TestAccessorMatrixConformance.m + TestCoverageGapWatchdog.m) to
 * exercise each first-class SpectralDataset accessor in isolation.
 *
 * Cross-language equivalents:
 *   Java   global.thalion.ttio.transport.FixtureBuilder
 *          (commit 2d04e035)
 *   Python python/tests/_v0_11_fixtures.py
 *
 * Determinism: each fixture is byte-stable across runs (HDF5's
 * deterministic-on-write guarantees notwithstanding). Sequence bytes
 * are constant by design; image cubes use the formula
 * intensity = (k+1) * pixelIdx so pixel (0,0) is zero everywhere.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef TTIO_V011_FIXTURE_BUILDER_H
#define TTIO_V011_FIXTURE_BUILDER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TTIOV011FixtureBuilder : NSObject

/** Reference only: 1 ReferenceImport with 3 contigs
 *  (chr_long 6000 'A', chr_medium 1000 'C', chr_short 18-byte mix). */
+ (BOOL)buildReferenceOnlyAtPath:(NSString *)path
                            error:(NSError * _Nullable * _Nullable)error;

/** MS runs only: 1 AcquisitionRun (run_0001) with 5 spectra of 4 m/z
 *  points each. Mirrors the shape used by TransportConformanceTest. */
+ (BOOL)buildMsRunsOnlyAtPath:(NSString *)path
                         error:(NSError * _Nullable * _Nullable)error;

/** Genomic runs only: 1 WrittenGenomicRun (genomic_0001) with 4
 *  short aligned reads on chr1/chr1/chr2/*. Mirrors the shape used
 *  by TestM89GenomicTransport. */
+ (BOOL)buildGenomicRunsOnlyAtPath:(NSString *)path
                              error:(NSError * _Nullable * _Nullable)error;

/** The GENOMIC_RUNS run in the blocks_v1 layout (the writer default):
 *  three chromosomes, three blocks. */
+ (BOOL)buildGenomicRunsBlocksAtPath:(NSString *)path
                                error:(NSError * _Nullable * _Nullable)error;

/** Image only (continuous mode): 4x4x5 cube with deterministic
 *  intensities = (k+1) * (x + y*width). mz_axis = [100, 110, 120,
 *  130, 140]. */
+ (BOOL)buildImageMsContinuousAtPath:(NSString *)path
                                 error:(NSError * _Nullable * _Nullable)error;

/** Identifications only: 2 rows
 *  ({run1, 42, CompoundA, 0.91, [e1,e2]}
 *   {run1, 43, CompoundB, 0.85, [e3]}). */
+ (BOOL)buildIdentificationsOnlyAtPath:(NSString *)path
                                   error:(NSError * _Nullable * _Nullable)error;

/** Quantifications only: 2 rows for CompoundA/B on sample-1
 *  with intensity-sum normalisation and "counts" unit. */
+ (BOOL)buildQuantificationsOnlyAtPath:(NSString *)path
                                   error:(NSError * _Nullable * _Nullable)error;

/** Dataset provenance only: 2 ProvenanceRecord entries (one rich
 *  with parameters + input/output refs, one minimal). */
+ (BOOL)buildDatasetProvenanceOnlyAtPath:(NSString *)path
                                     error:(NSError * _Nullable * _Nullable)error;

/** Encryption algorithm only: root @encrypted attribute =
 *  "aes-256-gcm". No payload encryption — just the algorithm string
 *  on the open root group so isEncrypted / encryptedAlgorithm
 *  surface non-empty on open. */
+ (BOOL)buildEncryptionAlgorithmOnlyAtPath:(NSString *)path
                                       error:(NSError * _Nullable * _Nullable)error;

/** Everything: every populated accessor at once. 1 reference (3
 *  contigs), 3x3x4 MSImage, 2 ids, 2 quants, 2 provenance,
 *  @encrypted = "aes-256-gcm", 1 MS run (5 spectra of 4 m/z), 1
 *  genomic run (4 short reads), Task 6.6: 2 TTIOSubject + 3
 *  TTIOSample rows exercising every spec §8 cross-cardinality case.
 *  Used by TestCoverageGapWatchdog. */
+ (BOOL)buildEverythingAtPath:(NSString *)path
                          error:(NSError * _Nullable * _Nullable)error;

#pragma mark - Stage 5 (Task 5.6) fixtures

/** MS image — processed/sparse wire mode. The on-disk .tio is
 *  identical to +buildImageMsContinuousAtPath: — only the encode
 *  step differs (the MS_IMAGE_PROCESSED accessor's `encodeBlock`
 *  emits the MS image block via -writeImageProcessed: instead of
 *  -writeImage:). */
+ (BOOL)buildImageMsProcessedOnlyAtPath:(NSString *)path
                                    error:(NSError * _Nullable * _Nullable)error;

/** Raman image only: 3x3x5 cube, intensity[i] = i*0.5,
 *  wavenumbers = [1000, 1100, 1200, 1300, 1400] cm-1,
 *  excitation = 785.0 nm, laser power = 50.0 mW,
 *  scan = "raster", pixel size = 10.0 x 10.0. Matches the Java +
 *  Python siblings byte-for-byte. */
+ (BOOL)buildRamanImageOnlyAtPath:(NSString *)path
                              error:(NSError * _Nullable * _Nullable)error;

/** IR image only: 3x3x5 cube, intensity[i] = i*0.5,
 *  wavenumbers = [1000, 1100, 1200, 1300, 1400] cm-1,
 *  mode = TTIOIRModeAbsorbance, resolution = 4.0 cm-1,
 *  scan = "raster", pixel size = 10.0 x 10.0. Matches the Java +
 *  Python siblings byte-for-byte. */
+ (BOOL)buildIrImageOnlyAtPath:(NSString *)path
                           error:(NSError * _Nullable * _Nullable)error;

#pragma mark - Stage 6 (Task 6.6) fixtures (Deferral 2)

/** Subjects only: 2 TTIOSubject rows persisted as per-row HDF5
 *  groups under /study/subjects/. Row 0: SUBJ-A (minimal — external_id
 *  only, all optionals at unset sentinel). Row 1: SUBJ-B (fully
 *  populated — project=PROJ_A, sex=F, birth_year=1985, multi-key
 *  attributes map). Matches the Java + Python siblings byte-for-byte
 *  on the JSON attributes (sort-keys order). */
+ (BOOL)buildSubjectsOnlyAtPath:(NSString *)path
                            error:(NSError * _Nullable * _Nullable)error;

/** Samples only: 3 TTIOSample rows persisted as per-row HDF5
 *  groups under /study/samples/. Row 0: SMPL-1 (minimal). Row 1:
 *  SMPL-2 (subject_external_id=SUBJ-MISSING — soft-FK miss; per
 *  spec §4.4 this is allowed and only logs a WARNING). Row 2:
 *  SMPL-3 (fully populated, multi-key attributes). Matches the
 *  Java + Python siblings. */
+ (BOOL)buildSamplesOnlyAtPath:(NSString *)path
                           error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif

/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Storage provider protocols — Milestone 39 Part A.
 *
 * All three shipping providers (HDF5, memory, and — eventually —
 * Zarr/SQLite) implement these protocols. Upper layers
 * (MPGOSpectralDataset, MPGOAcquisitionRun, MPGOCompoundIO,
 * MPGOSignatureManager, MPGOEncryptionManager, MPGOKeyRotationManager,
 * MPGOAnonymizer, MPGOFeatureFlags) talk only to the protocols.
 */

#ifndef MPGO_STORAGE_PROTOCOLS_H
#define MPGO_STORAGE_PROTOCOLS_H

#import <Foundation/Foundation.h>
#import "MPGOCompoundField.h"
#import "ValueClasses/MPGOEnums.h"

typedef NS_ENUM(NSInteger, MPGOStorageOpenMode) {
    MPGOStorageOpenModeRead      = 0,  ///< read-only
    MPGOStorageOpenModeReadWrite = 1,  ///< read/write existing
    MPGOStorageOpenModeCreate    = 2,  ///< create/truncate
    MPGOStorageOpenModeAppend    = 3,  ///< append, creating if missing
};

@protocol MPGOStorageDataset;
@protocol MPGOStorageGroup;
@protocol MPGOStorageProvider;

// ──────────────────────────────────────────────────────────────
// Dataset
// ──────────────────────────────────────────────────────────────

/**
 * A typed array (or compound record array) stored under an
 * MPGOStorageGroup. 1-D is the common case; N-D is supported for
 * image cubes and 2-D NMR data.
 *
 * API status: Stable (Provisional per M39 — may change before v1.0).
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.providers.base.StorageDataset
 *   Java:   com.dtwthalion.mpgo.providers.StorageDataset
 */
@protocol MPGOStorageDataset <NSObject>

- (NSString *)name;
- (MPGOPrecision)precision;  ///< meaningful only for primitive datasets
- (NSArray<NSNumber *> *)shape;   ///< full shape; 1-D returns @[@N]
- (NSArray<NSNumber *> *)chunks;  ///< chunk shape, or nil for contiguous
- (NSUInteger)length;             ///< convenience: shape[0]
- (NSArray<MPGOCompoundField *> *)compoundFields;  ///< nil for primitives

/** Full read. Primitive datasets return NSData of length * sizeof(element);
 *  compound datasets return NSArray<NSDictionary *> where each dict maps
 *  field name to boxed value. */
- (id)readAll:(NSError **)error;

/** Hyperslab read. */
- (id)readSliceAtOffset:(NSUInteger)offset
                  count:(NSUInteger)count
                  error:(NSError **)error;

/** Write. For primitives, ``data`` is NSData of length * sizeof(element);
 *  for compound, an NSArray<NSDictionary *>. */
- (BOOL)writeAll:(id)data error:(NSError **)error;

- (BOOL)hasAttributeNamed:(NSString *)name;
- (id)attributeValueForName:(NSString *)name error:(NSError **)error;
- (BOOL)setAttributeValue:(id)value
                  forName:(NSString *)name
                    error:(NSError **)error;

@optional
- (void)close;

@end

// ──────────────────────────────────────────────────────────────
// Group
// ──────────────────────────────────────────────────────────────

/**
 * A named directory of sub-groups and datasets.
 *
 * Groups form a hierarchical namespace. Every provider exposes at
 * least one root group via MPGOStorageProvider. Upper-layer objects
 * (MPGOSpectralDataset, MPGOAcquisitionRun, etc.) navigate the tree
 * exclusively through this protocol.
 *
 * API status: Stable (Provisional per M39 — may change before v1.0).
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.providers.base.StorageGroup
 *   Java:   com.dtwthalion.mpgo.providers.StorageGroup
 */
@protocol MPGOStorageGroup <NSObject>

- (NSString *)name;

// Children
- (NSArray<NSString *> *)childNames;
- (BOOL)hasChildNamed:(NSString *)name;
- (id<MPGOStorageGroup>)openGroupNamed:(NSString *)name error:(NSError **)error;
- (id<MPGOStorageGroup>)createGroupNamed:(NSString *)name error:(NSError **)error;
- (BOOL)deleteChildNamed:(NSString *)name error:(NSError **)error;

// Datasets
- (id<MPGOStorageDataset>)openDatasetNamed:(NSString *)name error:(NSError **)error;

- (id<MPGOStorageDataset>)createDatasetNamed:(NSString *)name
                                    precision:(MPGOPrecision)precision
                                       length:(NSUInteger)length
                                    chunkSize:(NSUInteger)chunkSize
                                  compression:(MPGOCompression)compression
                             compressionLevel:(int)compressionLevel
                                        error:(NSError **)error;

/** Create an N-D dataset. Returns nil + ``MPGOErrorDatasetCreate`` when
 *  the provider does not support the requested rank. */
- (id<MPGOStorageDataset>)createDatasetNDNamed:(NSString *)name
                                      precision:(MPGOPrecision)precision
                                          shape:(NSArray<NSNumber *> *)shape
                                         chunks:(NSArray<NSNumber *> *)chunks
                                    compression:(MPGOCompression)compression
                               compressionLevel:(int)compressionLevel
                                          error:(NSError **)error;

- (id<MPGOStorageDataset>)createCompoundDatasetNamed:(NSString *)name
                                                fields:(NSArray<MPGOCompoundField *> *)fields
                                                 count:(NSUInteger)count
                                                 error:(NSError **)error;

// Attributes
- (BOOL)hasAttributeNamed:(NSString *)name;
- (id)attributeValueForName:(NSString *)name error:(NSError **)error;
- (BOOL)setAttributeValue:(id)value
                  forName:(NSString *)name
                    error:(NSError **)error;
- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error;
- (NSArray<NSString *> *)attributeNames;

@optional
- (void)close;

@end

// ──────────────────────────────────────────────────────────────
// Provider
// ──────────────────────────────────────────────────────────────

/**
 * Storage backend entry point.
 *
 * A provider opens a backing store (HDF5 file, in-memory tree, future
 * Zarr store, etc.) and exposes its root MPGOStorageGroup. Providers
 * are selected by scheme-based routing via @c supportsURL: or named
 * explicitly. Upper layers talk only to the protocols and stay
 * backend-agnostic.
 *
 * API status: Stable (Provisional per M39 — may change before v1.0).
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.providers.base.StorageProvider
 *   Java:   com.dtwthalion.mpgo.providers.StorageProvider
 */
@protocol MPGOStorageProvider <NSObject>

- (NSString *)providerName;           ///< "hdf5", "memory", …
- (BOOL)supportsURL:(NSString *)url;  ///< used for scheme-based routing
- (BOOL)openURL:(NSString *)url
           mode:(MPGOStorageOpenMode)mode
          error:(NSError **)error;
- (id<MPGOStorageGroup>)rootGroupWithError:(NSError **)error;
- (BOOL)isOpen;
- (void)close;

/** Escape hatch returning the underlying native handle
 *  (``MPGOHDF5File`` for the HDF5 provider, nil for memory).
 *  Byte-level callers (signatures, encryption) use this. */
- (id)nativeHandle;

@end

#endif  /* MPGO_STORAGE_PROTOCOLS_H */

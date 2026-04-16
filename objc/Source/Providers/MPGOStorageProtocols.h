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

@protocol MPGOStorageDataset <NSObject>

- (NSString *)name;
- (MPGOPrecision)precision;  ///< meaningful only for primitive datasets
- (NSUInteger)length;
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

@protocol MPGOStorageProvider <NSObject>

- (NSString *)providerName;           ///< "hdf5", "memory", …
- (BOOL)supportsURL:(NSString *)url;  ///< used for scheme-based routing
- (BOOL)openURL:(NSString *)url
           mode:(MPGOStorageOpenMode)mode
          error:(NSError **)error;
- (id<MPGOStorageGroup>)rootGroupWithError:(NSError **)error;
- (BOOL)isOpen;
- (void)close;

@end

#endif  /* MPGO_STORAGE_PROTOCOLS_H */

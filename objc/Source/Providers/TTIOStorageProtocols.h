/*
 * Licensed under LGPL-3.0-or-later.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Storage provider protocols. All shipping providers (HDF5, memory,
 * SQLite, Zarr) implement these protocols. Upper layers
 * (TTIOSpectralDataset, TTIOAcquisitionRun, TTIOCompoundIO,
 * TTIOSignatureManager, TTIOEncryptionManager,
 * TTIOKeyRotationManager, TTIOAnonymizer, TTIOFeatureFlags) talk
 * only to the protocols.
 */

#ifndef TTIO_STORAGE_PROTOCOLS_H
#define TTIO_STORAGE_PROTOCOLS_H

#import <Foundation/Foundation.h>
#import "TTIOCompoundField.h"
#import "ValueClasses/TTIOEnums.h"

typedef NS_ENUM(NSInteger, TTIOStorageOpenMode) {
    TTIOStorageOpenModeRead      = 0,  ///< read-only
    TTIOStorageOpenModeReadWrite = 1,  ///< read/write existing
    TTIOStorageOpenModeCreate    = 2,  ///< create/truncate
    TTIOStorageOpenModeAppend    = 3,  ///< append, creating if missing
};

@protocol TTIOStorageDataset;
@protocol TTIOStorageGroup;
@protocol TTIOStorageProvider;

// ──────────────────────────────────────────────────────────────
// Dataset
// ──────────────────────────────────────────────────────────────

/**
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Providers/TTIOStorageProtocols.h</p>
 *
 * <p>A typed array (or compound record array) stored under a
 * <code>TTIOStorageGroup</code>. 1-D is the common case; N-D is
 * supported for image cubes and 2-D NMR data.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.providers.base.StorageDataset</code><br/>
 * Java:
 * <code>global.thalion.ttio.providers.StorageDataset</code></p>
 */
@protocol TTIOStorageDataset <NSObject>

- (NSString *)name;
- (TTIOPrecision)precision;  ///< meaningful only for primitive datasets
- (NSArray<NSNumber *> *)shape;   ///< full shape; 1-D returns @[@N]
- (NSArray<NSNumber *> *)chunks;  ///< chunk shape, or nil for contiguous
- (NSUInteger)length;             ///< convenience: shape[0]
- (NSArray<TTIOCompoundField *> *)compoundFields;  ///< nil for primitives

/** Full read.
 *
 *  Return type varies by backend:
 *    - Primitive datasets: <code>NSData</code> of
 *      <code>length * sizeof(element)</code>.
 *    - Compound datasets (all backends):
 *      <code>NSArray&lt;NSDictionary *&gt;</code> where each dict
 *      maps field name to boxed value. The ObjC reference
 *      implementation returns this shape for both HDF5 and SQLite
 *      providers, so callers do not need to branch on provider type.
 *      The universal helper <code>-readRows:</code> returns the same
 *      value and is provided for cross-language parity with Python
 *      and Java. */
- (id)readAll:(NSError **)error;

/** Hyperslab read. */
- (id)readSliceAtOffset:(NSUInteger)offset
                  count:(NSUInteger)count
                  error:(NSError **)error;

/** Write. For primitives, ``data`` is NSData of length * sizeof(element);
 *  for compound, an NSArray&lt;NSDictionary *&gt;. */
- (BOOL)writeAll:(id)data error:(NSError **)error;

/** Backend-agnostic compound read. Returns
 *  <code>NSArray&lt;NSDictionary *&gt;</code> for compound datasets,
 *  <code>nil</code> + <code>NSError</code> for primitives.
 *
 *  ObjC compound readers already return the
 *  <code>NSDictionary</code> shape universally, so most
 *  implementations are a trivial forwarder to
 *  <code>-readAll:</code>. Required on the protocol so that custom
 *  provider implementations that omit it fail at compile time rather
 *  than silently at runtime via
 *  <code>doesNotRecognizeSelector:</code>. */
- (NSArray<NSDictionary<NSString *, id> *> *)readRows:(NSError **)error;

/** Returns the dataset contents as a byte stream in the TTIO
 *  canonical layout.
 *
 *  Semantics:
 *    - Primitive numeric: little-endian packed values.
 *    - Compound: rows in storage order; fields in declaration order.
 *      VL strings as u32_le(length) || utf-8_bytes. Numeric fields
 *      little-endian.
 *
 *  Signatures and encryption consume this so a signed or encrypted
 *  dataset verifies identically regardless of which provider wrote
 *  it. Required on the protocol because signature/encryption callers
 *  can never silently skip the canonicalisation step.
 *
 *  Returns nil on read failure; populated NSError on failure.
 */
- (NSData *)readCanonicalBytes:(NSError **)error;

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
// Group
// ──────────────────────────────────────────────────────────────

/**
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Providers/TTIOStorageProtocols.h</p>
 *
 * <p>A named directory of sub-groups and datasets. Groups form a
 * hierarchical namespace; every provider exposes at least one root
 * group via <code>TTIOStorageProvider</code>. Upper-layer objects
 * (<code>TTIOSpectralDataset</code>, <code>TTIOAcquisitionRun</code>,
 * ...) navigate the tree exclusively through this protocol.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.providers.base.StorageGroup</code><br/>
 * Java:
 * <code>global.thalion.ttio.providers.StorageGroup</code></p>
 */
@protocol TTIOStorageGroup <NSObject>

- (NSString *)name;

// Children
- (NSArray<NSString *> *)childNames;
- (BOOL)hasChildNamed:(NSString *)name;
- (id<TTIOStorageGroup>)openGroupNamed:(NSString *)name error:(NSError **)error;
- (id<TTIOStorageGroup>)createGroupNamed:(NSString *)name error:(NSError **)error;
- (BOOL)deleteChildNamed:(NSString *)name error:(NSError **)error;

// Datasets
- (id<TTIOStorageDataset>)openDatasetNamed:(NSString *)name error:(NSError **)error;

- (id<TTIOStorageDataset>)createDatasetNamed:(NSString *)name
                                    precision:(TTIOPrecision)precision
                                       length:(NSUInteger)length
                                    chunkSize:(NSUInteger)chunkSize
                                  compression:(TTIOCompression)compression
                             compressionLevel:(int)compressionLevel
                                        error:(NSError **)error;

/** Create an N-D dataset. Returns nil + ``TTIOErrorDatasetCreate`` when
 *  the provider does not support the requested rank. */
- (id<TTIOStorageDataset>)createDatasetNDNamed:(NSString *)name
                                      precision:(TTIOPrecision)precision
                                          shape:(NSArray<NSNumber *> *)shape
                                         chunks:(NSArray<NSNumber *> *)chunks
                                    compression:(TTIOCompression)compression
                               compressionLevel:(int)compressionLevel
                                          error:(NSError **)error;

- (id<TTIOStorageDataset>)createCompoundDatasetNamed:(NSString *)name
                                                fields:(NSArray<TTIOCompoundField *> *)fields
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
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Providers/TTIOStorageProtocols.h</p>
 *
 * <p>Storage backend entry point. A provider opens a backing store
 * (HDF5 file, in-memory tree, Zarr store, SQLite database, etc.)
 * and exposes its root <code>TTIOStorageGroup</code>. Providers are
 * selected by scheme-based routing via <code>-supportsURL:</code>
 * or named explicitly through
 * <code>TTIOProviderRegistry</code>. Upper layers talk only to the
 * protocols and stay backend-agnostic.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.providers.base.StorageProvider</code><br/>
 * Java:
 * <code>global.thalion.ttio.providers.StorageProvider</code></p>
 */
@protocol TTIOStorageProvider <NSObject>

- (NSString *)providerName;           ///< "hdf5", "memory", …
- (BOOL)supportsURL:(NSString *)url;  ///< used for scheme-based routing
- (BOOL)openURL:(NSString *)url
           mode:(TTIOStorageOpenMode)mode
          error:(NSError **)error;
- (id<TTIOStorageGroup>)rootGroupWithError:(NSError **)error;
- (BOOL)isOpen;
- (void)close;

/** Escape hatch returning the underlying native handle
 *  (``TTIOHDF5File`` for the HDF5 provider, nil for memory).
 *  Byte-level callers (signatures, encryption) use this. */
- (id)nativeHandle;

@optional
/** YES if the backend honors ``chunkSize`` in
 *  ``-createDatasetNamed:precision:length:chunkSize:...``. Defaults
 *  to NO via the adapter pattern — only ``TTIOHDF5Provider`` returns
 *  <code>YES</code>. Memory and SQLite accept the argument for
 *  interface compatibility but silently ignore it. */
- (BOOL)supportsChunking;

/** <code>YES</code> if the backend honors <code>compression</code> /
 *  <code>compressionLevel</code>. Only <code>TTIOHDF5Provider</code>
 *  returns <code>YES</code> (zlib + LZ4). */
- (BOOL)supportsCompression;

// ── Transactions ────────────────────────────────────────────────

/** Start a write-batching transaction. No-op on HDF5 and Memory;
 *  issues ``BEGIN`` on the underlying connection for SQLite. */
- (void)beginTransaction;

/** Commit and end a transaction started with ``-beginTransaction``.
 *  No-op on HDF5 and Memory. */
- (void)commitTransaction;

/** Roll back and end a transaction started with
 *  ``-beginTransaction``. No-op on HDF5 and Memory. */
- (void)rollbackTransaction;

@end

#endif  /* TTIO_STORAGE_PROTOCOLS_H */

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

/** Leaf name of the dataset within its parent group. */
- (NSString *)name;

/** Element precision of a primitive dataset. Meaningful only when ``compoundFields`` returns ``nil``. */
- (TTIOPrecision)precision;

/** Full shape as an array of boxed integers. 1-D datasets return ``@[@N]``. */
- (NSArray<NSNumber *> *)shape;

/** Chunk shape as an array of boxed integers, or ``nil`` for a contiguously stored dataset. */
- (NSArray<NSNumber *> *)chunks;

/** Convenience accessor returning ``shape[0]`` (the count along the first axis). */
- (NSUInteger)length;

/** Compound field schema in declaration order, or ``nil`` for a primitive dataset. */
- (NSArray<TTIOCompoundField *> *)compoundFields;

/**
 * Read the entire dataset.
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
 *      and Java.
 *
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return Backend-specific value as documented above, or ``nil`` on failure.
 */
- (id)readAll:(NSError **)error;

/**
 * Read a contiguous slice of the dataset.
 *
 * @param offset  Element index to start reading from (0-based).
 * @param count   Number of elements (primitive) or rows (compound)
 *                to return.
 * @param error   On failure, populated with an ``NSError``. May be
 *                ``NULL``.
 *
 * @return Slice in the same shape as ``-readAll:`` (NSData for
 *         primitive, NSArray of NSDictionary for compound), or
 *         ``nil`` on failure.
 */
- (id)readSliceAtOffset:(NSUInteger)offset
                  count:(NSUInteger)count
                  error:(NSError **)error;

/**
 * Overwrite the dataset.
 *
 * @param data   For primitives, ``NSData`` of
 *               ``length * sizeof(element)``. For compound, an
 *               ``NSArray<NSDictionary *>`` matching the field
 *               schema.
 * @param error  On failure, populated with an ``NSError``. May be ``NULL``.
 *
 * @return ``YES`` on success, ``NO`` on failure.
 */
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

/**
 * Return ``YES`` when an attribute of that name exists on the dataset.
 *
 * @param name Attribute name to probe.
 * @return ``YES`` if present, ``NO`` otherwise.
 */
- (BOOL)hasAttributeNamed:(NSString *)name;

/**
 * Return the value of a named attribute.
 *
 * @param name  Attribute name.
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return Boxed attribute value, or ``nil`` on failure / missing key.
 */
- (id)attributeValueForName:(NSString *)name error:(NSError **)error;

/**
 * Create or overwrite a named attribute.
 *
 * @param value  Scalar, NSData, NSArray, NSDictionary, or NSString
 *               accepted by the backend.
 * @param name   Attribute name.
 * @param error  On failure, populated with an ``NSError``. May be ``NULL``.
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)setAttributeValue:(id)value
                  forName:(NSString *)name
                    error:(NSError **)error;

/**
 * Remove an attribute by name.
 *
 * Idempotent: missing names succeed silently.
 *
 * @param name  Attribute name.
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error;

/** Return the list of attribute names defined on the dataset, in backend iteration order. */
- (NSArray<NSString *> *)attributeNames;

/** ``YES`` when the dataset was created extendable and accepts
 *  ``-appendData:error:``. */
- (BOOL)isExtendable;

/**
 * Grow the dataset along its first axis.
 *
 * @param data  Packed little-endian elements (``NSData``) for a
 *              primitive dataset, or ``NSArray<NSDictionary *>`` rows
 *              for a compound one.
 * @param error Populated with ``TTIOErrorDatasetWrite`` when the
 *              dataset is not extendable.
 */
- (BOOL)appendData:(id)data error:(NSError **)error;

/** Overwrite elements in place starting at ``offset``; the dataset
 *  does not grow. */
- (BOOL)writeSlice:(id)data atOffset:(NSUInteger)offset error:(NSError **)error;

@optional
/** Release the dataset's backend resources eagerly. Optional; not all providers maintain per-dataset state. */
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

/** Leaf name of the group within its parent, or ``"/"`` for the root group. */
- (NSString *)name;

// Children

/** Return immediate child names (groups and datasets) in backend iteration order. */
- (NSArray<NSString *> *)childNames;

/**
 * Return ``YES`` when a child of that name exists.
 *
 * @param name Immediate child name (not a slash-separated path).
 */
- (BOOL)hasChildNamed:(NSString *)name;

/**
 * Open an existing child group.
 *
 * @param name  Immediate child name.
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return Child group adapter, or ``nil`` when the child is missing
 *         or is a dataset.
 */
- (id<TTIOStorageGroup>)openGroupNamed:(NSString *)name error:(NSError **)error;

/**
 * Create a new child group.
 *
 * @param name  Immediate child name. Must not already exist.
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return Newly created group adapter, or ``nil`` on failure.
 */
- (id<TTIOStorageGroup>)createGroupNamed:(NSString *)name error:(NSError **)error;

/**
 * Remove a child group or dataset.
 *
 * Idempotent: missing names succeed silently.
 *
 * @param name  Immediate child name.
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)deleteChildNamed:(NSString *)name error:(NSError **)error;

// Datasets

/**
 * Open an existing child as a dataset.
 *
 * @param name  Immediate child name.
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return Dataset adapter, or ``nil`` when the child is missing or
 *         is a group.
 */
- (id<TTIOStorageDataset>)openDatasetNamed:(NSString *)name error:(NSError **)error;

/**
 * Create a 1-D primitive dataset.
 *
 * @param name              Immediate child name. Must not already
 *                          exist.
 * @param precision         Element type.
 * @param length            Number of elements to allocate.
 * @param chunkSize         Chunk size along the axis. ``0`` disables
 *                          chunking (and therefore compression).
 *                          Honored only by providers whose
 *                          ``-supportsChunking`` returns ``YES``.
 * @param compression       Compression algorithm. Honored only by
 *                          providers whose ``-supportsCompression``
 *                          returns ``YES``.
 * @param compressionLevel  Codec-specific level (e.g. zlib 1..9).
 *                          Ignored by codecs that don't take a
 *                          level.
 * @param error             On failure, populated with an
 *                          ``NSError``. May be ``NULL``.
 *
 * @return Newly created dataset adapter, or ``nil`` on failure.
 */
- (id<TTIOStorageDataset>)createDatasetNamed:(NSString *)name
                                    precision:(TTIOPrecision)precision
                                       length:(NSUInteger)length
                                    chunkSize:(NSUInteger)chunkSize
                                  compression:(TTIOCompression)compression
                             compressionLevel:(int)compressionLevel
                                        error:(NSError **)error;

/**
 * Create an N-D primitive dataset.
 *
 * Used for image cubes and 2-D NMR cubes.
 *
 * @param name              Immediate child name. Must not already exist.
 * @param precision         Element type.
 * @param shape             Per-dimension lengths.
 * @param chunks            Per-dimension chunk shape, or ``nil`` for
 *                          contiguous storage.
 * @param compression       Compression algorithm.
 * @param compressionLevel  Codec-specific level.
 * @param error             On failure, populated with an
 *                          ``NSError``. May be ``NULL``.
 *
 * @return Newly created dataset adapter, or ``nil`` with
 *         ``TTIOErrorDatasetCreate`` when the provider does not
 *         support the requested rank.
 */
- (id<TTIOStorageDataset>)createDatasetNDNamed:(NSString *)name
                                      precision:(TTIOPrecision)precision
                                          shape:(NSArray<NSNumber *> *)shape
                                         chunks:(NSArray<NSNumber *> *)chunks
                                    compression:(TTIOCompression)compression
                               compressionLevel:(int)compressionLevel
                                          error:(NSError **)error;

/**
 * Create a compound-record dataset.
 *
 * @param name   Immediate child name. Must not already exist.
 * @param fields Field schema in declaration order.
 * @param count  Number of records (rows) to allocate.
 * @param error  On failure, populated with an ``NSError``. May be ``NULL``.
 *
 * @return Newly created dataset adapter, or ``nil`` on failure.
 */
- (id<TTIOStorageDataset>)createCompoundDatasetNamed:(NSString *)name
                                                fields:(NSArray<TTIOCompoundField *> *)fields
                                                 count:(NSUInteger)count
                                                 error:(NSError **)error;

/**
 * Create a primitive 1-D dataset, optionally extendable along its
 * single axis (``chunkSize`` must then be > 0). Extendable datasets
 * accept ``-appendData:error:``.
 */
- (id<TTIOStorageDataset>)createDatasetNamed:(NSString *)name
                                    precision:(TTIOPrecision)precision
                                       length:(NSUInteger)length
                                    chunkSize:(NSUInteger)chunkSize
                                  compression:(TTIOCompression)compression
                             compressionLevel:(int)compressionLevel
                                   extendable:(BOOL)extendable
                                        error:(NSError **)error;

/**
 * Create a compound dataset, optionally extendable in rows of
 * ``chunkRows`` (must then be > 0). HDF5 extendable compounds take
 * primitive field kinds only.
 */
- (id<TTIOStorageDataset>)createCompoundDatasetNamed:(NSString *)name
                                                fields:(NSArray<TTIOCompoundField *> *)fields
                                                 count:(NSUInteger)count
                                            extendable:(BOOL)extendable
                                             chunkRows:(NSUInteger)chunkRows
                                                 error:(NSError **)error;

// Attributes

/** Return ``YES`` when an attribute of that name exists on the group. */
- (BOOL)hasAttributeNamed:(NSString *)name;

/**
 * Return the value of a named attribute on the group.
 *
 * @param name  Attribute name.
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return Boxed attribute value, or ``nil`` on failure / missing key.
 */
- (id)attributeValueForName:(NSString *)name error:(NSError **)error;

/**
 * Create or overwrite a named attribute on the group.
 *
 * @param value  Scalar, NSData, NSArray, NSDictionary, or NSString.
 * @param name   Attribute name.
 * @param error  On failure, populated with an ``NSError``. May be ``NULL``.
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)setAttributeValue:(id)value
                  forName:(NSString *)name
                    error:(NSError **)error;

/**
 * Remove an attribute on the group by name. Idempotent.
 *
 * @param name  Attribute name.
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)deleteAttributeNamed:(NSString *)name error:(NSError **)error;

/** Return the list of attribute names defined on the group. */
- (NSArray<NSString *> *)attributeNames;

@optional
/** Release the group's backend resources eagerly. Optional; not all providers maintain per-group state. */
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

/** Stable provider identifier string (``"hdf5"``, ``"memory"``, ``"sqlite"``, ``"zarr"``). */
- (NSString *)providerName;

/**
 * Return ``YES`` when this provider can open ``url``.
 *
 * Used by ``TTIOProviderRegistry`` for scheme-based routing.
 *
 * @param url URL or filesystem path to probe.
 */
- (BOOL)supportsURL:(NSString *)url;

/**
 * Open the backing store at ``url`` in ``mode``.
 *
 * @param url    Filesystem path or scheme-qualified URL.
 * @param mode   Read / read-write / create / append mode.
 * @param error  On failure, populated with an ``NSError``. May be ``NULL``.
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)openURL:(NSString *)url
           mode:(TTIOStorageOpenMode)mode
          error:(NSError **)error;

/**
 * Return the root group of the open backing store.
 *
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return Root group adapter, or ``nil`` when the provider is not
 *         open.
 */
- (id<TTIOStorageGroup>)rootGroupWithError:(NSError **)error;

/** Return ``YES`` when the provider currently has an open backing store. */
- (BOOL)isOpen;

/** Close the backing store. Idempotent; safe to call from cleanup paths. */
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

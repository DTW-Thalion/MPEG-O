/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_HDF5_PROVIDER_H
#define TTIO_HDF5_PROVIDER_H

#import <Foundation/Foundation.h>
#import "TTIOStorageProtocols.h"

@class TTIOHDF5Group;
@class TTIOHDF5Dataset;
@class TTIOCompoundField;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> TTIOStorageProvider, NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Providers/TTIOHDF5Provider.h</p>
 *
 * <p>HDF5 storage provider. Adapter over the existing
 * <code>TTIOHDF5File</code> / <code>TTIOHDF5Group</code> /
 * <code>TTIOHDF5Dataset</code> layer &#8212; no behavioural change.
 * Registers for both <code>file://</code> and bare-path URLs via
 * <code>+load</code>.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.providers.hdf5.Hdf5Provider</code><br/>
 * Java:
 * <code>global.thalion.ttio.providers.Hdf5Provider</code></p>
 */
@interface TTIOHDF5Provider : NSObject <TTIOStorageProvider>

/**
 * Wraps a raw HDF5 group in the provider adapter so callers holding
 * a <code>TTIOHDF5Group</code> instance (acquisition runs, MSImage
 * write path) can hand it off as
 * <code>id&lt;TTIOStorageGroup&gt;</code>. No ownership transfer;
 * caller retains the underlying HDF5 handle lifetime.
 *
 * @param group HDF5 group to wrap.
 * @return Adapter conforming to <code>TTIOStorageGroup</code>.
 */
+ (id<TTIOStorageGroup>)adapterForGroup:(TTIOHDF5Group *)group;

/**
 * Wraps a raw HDF5 dataset as
 * <code>id&lt;TTIOStorageDataset&gt;</code>. Same ownership
 * semantics as <code>+adapterForGroup:</code>.
 *
 * @param dataset HDF5 dataset to wrap.
 * @param name    Dataset name to surface through the adapter.
 * @return Adapter conforming to <code>TTIOStorageDataset</code>.
 */
+ (id<TTIOStorageDataset>)adapterForDataset:(TTIOHDF5Dataset *)dataset
                                         name:(NSString *)name;

/**
 * Lazy compound-dataset adapter for the
 * <code>-createCompoundDatasetNamed:fields:count:error:</code>
 * protocol method when called on a raw <code>TTIOHDF5Group</code>.
 * The first <code>-writeAll:</code> materialises the H5T compound
 * type via the existing <code>TTIOCompoundIO</code> fast path, so
 * the HDF5 byte format is preserved.
 *
 * @param parent Owning HDF5 group.
 * @param name   Dataset name.
 * @param fields Compound field schema.
 * @param count  Row count.
 * @return Adapter conforming to <code>TTIOStorageDataset</code>.
 */
+ (id<TTIOStorageDataset>)adapterForCompoundDatasetWithParent:(TTIOHDF5Group *)parent
                                                          name:(NSString *)name
                                                        fields:(NSArray<TTIOCompoundField *> *)fields
                                                         count:(NSUInteger)count;

@end

#endif

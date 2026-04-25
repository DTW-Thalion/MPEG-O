/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_HDF5_PROVIDER_H
#define TTIO_HDF5_PROVIDER_H

#import <Foundation/Foundation.h>
#import "TTIOStorageProtocols.h"

@class TTIOHDF5Group;
@class TTIOHDF5Dataset;

/**
 * HDF5 storage provider. Adapter over the existing
 * TTIOHDF5File/Group/Dataset layer — no behavioural change.
 * Registers for both "file://" and bare-path URLs via +load.
 *
 * API status: Stable (Provisional per M39 — may change before v1.0).
 *
 * Cross-language equivalents:
 *   Python: ttio.providers.hdf5.Hdf5Provider
 *   Java:   global.thalion.ttio.providers.Hdf5Provider
 */
@interface TTIOHDF5Provider : NSObject <TTIOStorageProvider>

/** v0.7 M44: wrap a raw HDF5 group in the provider adapter so
 *  callers holding an ``TTIOHDF5Group`` instance (Acquisitionrun,
 *  MSImage write path) can hand it off as a protocol
 *  ``id<TTIOStorageGroup>``. No ownership transfer; caller retains
 *  the underlying HDF5 handle lifetime.
 *
 *  @since 0.7 */
+ (id<TTIOStorageGroup>)adapterForGroup:(TTIOHDF5Group *)group;

/** v0.7 M44: wrap a raw HDF5 dataset as an ``id<TTIOStorageDataset>``.
 *  Same ownership semantics as ``+adapterForGroup:``.
 *
 *  @since 0.7 */
+ (id<TTIOStorageDataset>)adapterForDataset:(TTIOHDF5Dataset *)dataset
                                         name:(NSString *)name;

@end

#endif

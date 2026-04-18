/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_HDF5_PROVIDER_H
#define MPGO_HDF5_PROVIDER_H

#import <Foundation/Foundation.h>
#import "MPGOStorageProtocols.h"

@class MPGOHDF5Group;
@class MPGOHDF5Dataset;

/**
 * HDF5 storage provider. Adapter over the existing
 * MPGOHDF5File/Group/Dataset layer — no behavioural change.
 * Registers for both "file://" and bare-path URLs via +load.
 *
 * API status: Stable (Provisional per M39 — may change before v1.0).
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.providers.hdf5.Hdf5Provider
 *   Java:   com.dtwthalion.mpgo.providers.Hdf5Provider
 */
@interface MPGOHDF5Provider : NSObject <MPGOStorageProvider>

/** v0.7 M44: wrap a raw HDF5 group in the provider adapter so
 *  callers holding an ``MPGOHDF5Group`` instance (Acquisitionrun,
 *  MSImage write path) can hand it off as a protocol
 *  ``id<MPGOStorageGroup>``. No ownership transfer; caller retains
 *  the underlying HDF5 handle lifetime.
 *
 *  @since 0.7 */
+ (id<MPGOStorageGroup>)adapterForGroup:(MPGOHDF5Group *)group;

/** v0.7 M44: wrap a raw HDF5 dataset as an ``id<MPGOStorageDataset>``.
 *  Same ownership semantics as ``+adapterForGroup:``.
 *
 *  @since 0.7 */
+ (id<MPGOStorageDataset>)adapterForDataset:(MPGOHDF5Dataset *)dataset
                                         name:(NSString *)name;

@end

#endif

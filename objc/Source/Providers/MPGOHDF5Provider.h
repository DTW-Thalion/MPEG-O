/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_HDF5_PROVIDER_H
#define MPGO_HDF5_PROVIDER_H

#import <Foundation/Foundation.h>
#import "MPGOStorageProtocols.h"

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
@end

#endif

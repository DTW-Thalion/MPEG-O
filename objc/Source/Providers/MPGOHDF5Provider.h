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
 */
@interface MPGOHDF5Provider : NSObject <MPGOStorageProvider>
@end

#endif

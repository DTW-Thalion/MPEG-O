/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_MEMORY_PROVIDER_H
#define MPGO_MEMORY_PROVIDER_H

#import <Foundation/Foundation.h>
#import "MPGOStorageProtocols.h"

/**
 * In-memory storage provider. URLs look like ``memory://<name>``;
 * opening the same name twice returns the same tree until
 * +discardStore: clears it. Exists alongside MPGOHDF5Provider to prove
 * the abstraction works — if upper layers read/write identically
 * through both, the protocol contract is correct.
 */
@interface MPGOMemoryProvider : NSObject <MPGOStorageProvider>

+ (void)discardStore:(NSString *)url;

@end

#endif

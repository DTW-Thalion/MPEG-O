/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_MEMORY_PROVIDER_H
#define MPGO_MEMORY_PROVIDER_H

#import <Foundation/Foundation.h>
#import "MPGOStorageProtocols.h"

/**
 * In-memory storage provider. URLs look like ``memory://&lt;name&gt;``;
 * opening the same name twice returns the same tree until
 * +discardStore: clears it. Exists alongside MPGOHDF5Provider to prove
 * the abstraction works — if upper layers read/write identically
 * through both, the protocol contract is correct.
 *
 * API status: Stable (Provisional per M39 — may change before v1.0).
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.providers.memory.MemoryProvider
 *   Java:   com.dtwthalion.mpgo.providers.MemoryProvider
 */
@interface MPGOMemoryProvider : NSObject <MPGOStorageProvider>

+ (void)discardStore:(NSString *)url;

@end

#endif

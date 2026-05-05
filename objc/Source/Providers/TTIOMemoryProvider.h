/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_MEMORY_PROVIDER_H
#define TTIO_MEMORY_PROVIDER_H

#import <Foundation/Foundation.h>
#import "TTIOStorageProtocols.h"

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> TTIOStorageProvider, NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Providers/TTIOMemoryProvider.h</p>
 *
 * <p>In-memory storage provider. URLs look like
 * <code>memory://&lt;name&gt;</code>; opening the same name twice
 * returns the same tree until <code>+discardStore:</code> clears it.
 * Exists alongside <code>TTIOHDF5Provider</code> to prove the
 * abstraction works &#8212; if upper layers read and write
 * identically through both, the protocol contract is correct.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.providers.memory.MemoryProvider</code><br/>
 * Java:
 * <code>global.thalion.ttio.providers.MemoryProvider</code></p>
 */
@interface TTIOMemoryProvider : NSObject <TTIOStorageProvider>

/**
 * Drops the named in-memory store. Subsequent opens of the same URL
 * see a fresh empty tree.
 *
 * @param url Memory URL of the store to discard.
 */
+ (void)discardStore:(NSString *)url;

@end

#endif

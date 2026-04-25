/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_PROVIDER_REGISTRY_H
#define TTIO_PROVIDER_REGISTRY_H

#import <Foundation/Foundation.h>
#import "TTIOStorageProtocols.h"

/**
 * Provider registry singleton. Providers self-register via +load.
 * Callers resolve by explicit name or URL scheme.
 *
 * API status: Stable (Provisional per M39 — may change before v1.0).
 *
 * Cross-language equivalents:
 *   Python: ttio.providers — module-level functions
 *           (discover_providers, open_provider, register_provider)
 *           — idiomatic for Python packaging.
 *   Java:   global.thalion.ttio.providers.ProviderRegistry class
 */
@interface TTIOProviderRegistry : NSObject

+ (instancetype)sharedRegistry;

- (void)registerProviderClass:(Class)providerClass
                     forName:(NSString *)name;

- (NSArray<NSString *> *)knownProviderNames;

/** Open a provider for a URL or bare path. ``providerName`` overrides
 *  scheme detection when non-nil. Returns nil with *error set on
 *  failure. */
- (id<TTIOStorageProvider>)openURL:(NSString *)url
                               mode:(TTIOStorageOpenMode)mode
                           provider:(NSString *)providerName
                              error:(NSError **)error;

@end

#endif

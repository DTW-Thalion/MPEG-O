/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_PROVIDER_REGISTRY_H
#define MPGO_PROVIDER_REGISTRY_H

#import <Foundation/Foundation.h>
#import "MPGOStorageProtocols.h"

/**
 * Provider registry singleton. Providers self-register via +load.
 * Callers resolve by explicit name or URL scheme.
 */
@interface MPGOProviderRegistry : NSObject

+ (instancetype)sharedRegistry;

- (void)registerProviderClass:(Class)providerClass
                     forName:(NSString *)name;

- (NSArray<NSString *> *)knownProviderNames;

/** Open a provider for a URL or bare path. ``providerName`` overrides
 *  scheme detection when non-nil. Returns nil with *error set on
 *  failure. */
- (id<MPGOStorageProvider>)openURL:(NSString *)url
                               mode:(MPGOStorageOpenMode)mode
                           provider:(NSString *)providerName
                              error:(NSError **)error;

@end

#endif

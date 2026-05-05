/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_PROVIDER_REGISTRY_H
#define TTIO_PROVIDER_REGISTRY_H

#import <Foundation/Foundation.h>
#import "TTIOStorageProtocols.h"

/**
 * <heading>TTIOProviderRegistry</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Providers/TTIOProviderRegistry.h</p>
 *
 * <p>Provider registry singleton. Concrete providers self-register
 * via <code>+load</code>. Callers resolve a provider by explicit
 * name or by URL scheme.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.providers</code> &mdash; module-level
 * <code>discover_providers</code>, <code>open_provider</code>,
 * <code>register_provider</code> (idiomatic for Python
 * packaging).<br/>
 * Java:
 * <code>global.thalion.ttio.providers.ProviderRegistry</code></p>
 */
@interface TTIOProviderRegistry : NSObject

/**
 * @return The shared registry instance.
 */
+ (instancetype)sharedRegistry;

/**
 * Registers a provider class under the given name. Subsequent
 * <code>-openURL:mode:provider:error:</code> calls naming this
 * provider, or matching its supported URL scheme, dispatch to it.
 *
 * @param providerClass Provider class conforming to
 *                      <code>TTIOStorageProvider</code>.
 * @param name          Short name (e.g. <code>@"hdf5"</code>,
 *                      <code>@"memory"</code>).
 */
- (void)registerProviderClass:(Class)providerClass
                     forName:(NSString *)name;

/**
 * @return Names of all currently registered providers.
 */
- (NSArray<NSString *> *)knownProviderNames;

/**
 * Opens a provider for a URL or bare path.
 *
 * @param url          URL or filesystem path.
 * @param mode         Open mode.
 * @param providerName Optional explicit provider name; overrides
 *                     scheme detection when non-<code>nil</code>.
 * @param error        Out-parameter populated on failure.
 * @return An opened provider, or <code>nil</code> on failure.
 */
- (id<TTIOStorageProvider>)openURL:(NSString *)url
                               mode:(TTIOStorageOpenMode)mode
                           provider:(NSString *)providerName
                              error:(NSError **)error;

@end

#endif

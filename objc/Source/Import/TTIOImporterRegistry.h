/*
 * TTIOImporterRegistry.h
 * TTI-O Objective-C Implementation
 *
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef TTIO_IMPORTER_REGISTRY_H
#define TTIO_IMPORTER_REGISTRY_H

#import <Foundation/Foundation.h>
#import "Import/TTIOReader.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Declared In:</em> Import/TTIOImporterRegistry.h</p>
 *
 * <p>One immutable entry in the importer registry: a canonical format
 * key paired with its GUI display name, file extensions, the external
 * tool it shells out to (or <code>nil</code>), and the
 * <code>TTIOReader</code> instance that parses inputs into a
 * <code>TTIOImportedDataset</code>.</p>
 *
 * <p>Mirrors Python <code>ttio.importers.registry.FormatSpec</code> and
 * Java <code>global.thalion.ttio.importers.ImporterRegistry.FormatSpec</code>.</p>
 */
@interface TTIOImporterFormatSpec : NSObject
/** Canonical lowercase key (e.g. <code>"mzml"</code>). */
@property (nonatomic, readonly, copy) NSString *key;
/** GUI-matching display label (e.g. <code>"mzML"</code>). */
@property (nonatomic, readonly, copy) NSString *displayName;
/** Recognised file extensions (e.g. <code>@[@".mzML"]</code>). */
@property (nonatomic, readonly, copy) NSArray<NSString *> *extensions;
/** External tool the importer needs at runtime, or <code>nil</code>. */
@property (nonatomic, readonly, copy, nullable) NSString *requiredTool;
/** Reader that parses inputs into a <code>TTIOImportedDataset</code>. */
@property (nonatomic, readonly, strong) id<TTIOReader> reader;
@end

/**
 * <p><em>Declared In:</em> Import/TTIOImporterRegistry.h</p>
 *
 * <p>Encode-format registry: the single source of truth for the formats
 * <code>ttio encode --format &lt;fmt&gt;</code> accepts and how each maps
 * to a <code>.tio</code>. Mirrors the Python
 * <code>ttio.importers.registry</code> module and the merged Java
 * <code>ImporterRegistry</code>; the canonical key set, alias table and
 * CLI-delegated formats are fenced for byte-parity across languages.</p>
 *
 * <p><code>fasta</code> / <code>fastq</code> are intentionally NOT
 * registered here: they keep their richer dedicated CLIs and are exposed
 * via <code>+supportedEncodeFormats</code> only (CLI_DELEGATED).</p>
 */
@interface TTIOImporterRegistry : NSObject

/** Canonicalises a user token: lowercase + trim + alias-map. */
+ (NSString *)normalizeFormat:(NSString *)format;

/** <code>YES</code> if the (normalised) format is a registry key. */
+ (BOOL)isRegistryFormat:(NSString *)format;

/** The spec for a format, or <code>nil</code> + error if unknown. */
+ (nullable TTIOImporterFormatSpec *)specForFormat:(NSString *)format
                                             error:(NSError *_Nullable *_Nullable)error;

/** The canonical registry keys, sorted ascending. */
+ (NSArray<NSString *> *)registryKeys;

/** All formats <code>encode</code> accepts: registry keys ∪ CLI_DELEGATED, sorted. */
+ (NSArray<NSString *> *)supportedEncodeFormats;

/**
 * Dispatches <code>inputs</code> &#8594; <code>output</code>
 * <code>.tio</code> for a registry format:
 * <code>[[spec.reader readInputs:...] writeToPath:output]</code>.
 *
 * @return <code>YES</code> on success; <code>NO</code> + error for an
 *         unknown format or a reader/write failure.
 */
+ (BOOL)encodeFormat:(NSString *)format
              inputs:(NSArray<NSString *> *)inputs
              output:(NSString *)output
             options:(NSDictionary<NSString *, id> *)options
               error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_IMPORTER_REGISTRY_H */

/*
 * TTIOExporterRegistry.h
 * TTI-O Objective-C Implementation
 *
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef TTIO_EXPORTER_REGISTRY_H
#define TTIO_EXPORTER_REGISTRY_H

#import <Foundation/Foundation.h>
#import "Export/TTIOWriter.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Declared In:</em> Export/TTIOExporterRegistry.h</p>
 *
 * <p>One immutable entry in the exporter registry: a canonical format
 * key paired with its GUI display name, output extensions, the external
 * tool it shells out to (or <code>nil</code>), and the
 * <code>TTIOWriter</code> instance that serializes one layer of an
 * opened dataset to an output path.</p>
 *
 * <p>Mirrors Python <code>ttio.exporters.registry.ExportSpec</code> and
 * Java <code>global.thalion.ttio.exporters.ExporterRegistry.ExportSpec</code>.</p>
 */
@interface TTIOExporterFormatSpec : NSObject
/** Canonical lowercase key (e.g. <code>"mzml"</code>). */
@property (nonatomic, readonly, copy) NSString *key;
/** GUI-matching display label (e.g. <code>"mzML"</code>). */
@property (nonatomic, readonly, copy) NSString *displayName;
/** Recognised output extensions. */
@property (nonatomic, readonly, copy) NSArray<NSString *> *extensions;
/** External tool the exporter needs at runtime, or <code>nil</code>. */
@property (nonatomic, readonly, copy, nullable) NSString *requiredTool;
/** Writer that serializes one layer to the output path. */
@property (nonatomic, readonly, strong) id<TTIOWriter> writer;
@end

/**
 * <p><em>Declared In:</em> Export/TTIOExporterRegistry.h</p>
 *
 * <p>Export-format registry: the single source of truth for the formats
 * <code>ttio export --format &lt;fmt&gt;</code> accepts and how each maps
 * a <code>.tio</code> layer to an output file. Mirrors the Python
 * <code>ttio.exporters.registry</code> module and the merged Java
 * <code>ExporterRegistry</code>; the canonical key set, alias table and
 * CLI-delegated formats are fenced for byte-parity across languages.</p>
 *
 * <p><code>fasta</code> / <code>fastq</code> are intentionally NOT
 * registered here (CLI_DELEGATED).</p>
 */
@interface TTIOExporterRegistry : NSObject

/** Canonicalises a user token: lowercase + trim + alias-map. */
+ (NSString *)normalizeFormat:(NSString *)format;

/** <code>YES</code> if the (normalised) format is a registry key. */
+ (BOOL)isRegistryFormat:(NSString *)format;

/** The spec for a format, or <code>nil</code> + error if unknown. */
+ (nullable TTIOExporterFormatSpec *)specForFormat:(NSString *)format
                                             error:(NSError *_Nullable *_Nullable)error;

/** The canonical registry keys, sorted ascending. */
+ (NSArray<NSString *> *)registryKeys;

/** All formats <code>export</code> accepts: registry keys ∪ CLI_DELEGATED, sorted. */
+ (NSArray<NSString *> *)supportedExportFormats;

/**
 * Dispatches a <code>.tio</code> &#8594; <code>output</code> for a
 * registry format: opens <code>tioPath</code> via
 * <code>+[TTIOSpectralDataset readFromFilePath:error:]</code>, then
 * <code>[spec.writer writeDataset:ds layer:layer toOutput:output ...]</code>.
 *
 * @return <code>YES</code> on success; <code>NO</code> + error for an
 *         unknown format or an open/write failure.
 */
+ (BOOL)exportFormat:(NSString *)format
             tioPath:(NSString *)tioPath
               layer:(nullable NSString *)layer
              output:(NSString *)output
             options:(NSDictionary<NSString *, id> *)options
               error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_EXPORTER_REGISTRY_H */

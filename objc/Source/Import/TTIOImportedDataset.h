/*
 * TTIOImportedDataset.h
 * TTI-O Objective-C Implementation
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#ifndef TTIO_IMPORTED_DATASET_H
#define TTIO_IMPORTED_DATASET_H

#import <Foundation/Foundation.h>
#import "Core/TTIOProgressSink.h"

@class TTIOSpectralDataset;
@class TTIOMSImage;
@class TTIORamanImage;
@class TTIOIRImage;
@class TTIOGenomicStreamSource;
@class TTIOSpectralStreamSource;

NS_ASSUME_NONNULL_BEGIN

/**
 * Write-through delegate signature. When set on a
 * <code>TTIOImportedDataset</code>, <code>-writeToPath:error:</code>
 * invokes the block instead of the in-memory
 * <code>+writeMinimalToPath:</code> path. Used by importers that do
 * not build in-memory runs (Bruker subprocess; imzML image
 * write-through via <code>TTIOMSImage</code>).
 */
typedef BOOL (^TTIOImportedDatasetWriteDelegate)(NSString *outputPath,
                                                 NSError *_Nullable *_Nullable error);

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Import/TTIOImportedDataset.h</p>
 *
 * <p>Normalized in-memory draft that every importer produces.
 * <code>-writeToPath:error:</code> is the SINGLE dataset-write site:
 * when <code>writeDelegate</code> is set it is used (subprocess /
 * image write-through importers); otherwise the draft is persisted
 * through
 * <code>+[TTIOSpectralDataset writeMinimalToPath:...mixedRuns:...]</code>.</p>
 *
 * <p><strong>Images.</strong> The <code>msImage</code> /
 * <code>ramanImage</code> / <code>irImage</code> properties are NOT
 * written by the non-delegate (writeMinimal) path, which has no image
 * parameter. Image persistence is performed by the imzML adapter's
 * write-through delegate (OT5). Setting an image without a delegate is
 * an importer bug and the image is ignored on the non-delegate path.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.ImportedDataset</code><br/>
 * Java: <code>global.thalion.ttio.importers.ImportedDataset</code></p>
 */
@interface TTIOImportedDataset : NSObject

/** Free-form dataset title. Defaults to an empty string. */
@property (nonatomic, copy) NSString *title;

/** ISA-Tab investigation identifier. Defaults to an empty string. */
@property (nonatomic, copy) NSString *isaInvestigationId;

/** MS runs keyed by name; values are <code>TTIOWrittenRun</code>. */
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *msRuns;

/** Genomic runs keyed by name; values are
 *  <code>TTIOWrittenGenomicRun</code>. */
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *genomicRuns;

/** Genomic runs delivered as batch streams; written after the static
 *  content through TTIOGenomicStreamWriter (blocks_v1). */
@property (nonatomic, strong) NSMutableDictionary<NSString *, TTIOGenomicStreamSource *> *genomicStreams;

/** Spectral runs delivered as batch streams; written after the static
 *  content through TTIOSpectralStreamWriter. */
@property (nonatomic, strong) NSMutableDictionary<NSString *, TTIOSpectralStreamSource *> *spectralStreams;

/** Dataset-wide identifications. */
@property (nonatomic, strong) NSMutableArray *identifications;

/** Dataset-wide quantifications. */
@property (nonatomic, strong) NSMutableArray *quantifications;

/** Dataset-wide provenance records. */
@property (nonatomic, strong) NSMutableArray *provenanceRecords;

/** Optional MS image (written only via a write-through delegate). */
@property (nonatomic, strong, nullable) TTIOMSImage *msImage;

/** Optional Raman image (written only via a write-through delegate). */
@property (nonatomic, strong, nullable) TTIORamanImage *ramanImage;

/** Optional IR image (written only via a write-through delegate). */
@property (nonatomic, strong, nullable) TTIOIRImage *irImage;

/** Optional write-through delegate; when set,
 *  <code>-writeToPath:error:</code> calls it instead of the
 *  writeMinimal path. */
@property (nonatomic, copy, nullable) TTIOImportedDatasetWriteDelegate writeDelegate;

/**
 * Convenience constructor for write-through importers.
 *
 * @param delegate The write-through block.
 * @return An imported-dataset draft whose <code>writeDelegate</code>
 *         is set.
 */
+ (instancetype)datasetWithWriteDelegate:(TTIOImportedDatasetWriteDelegate)delegate;

/**
 * Persists this draft to <code>path</code>. The single dataset-write
 * site. If <code>writeDelegate</code> is set it is invoked; otherwise
 * the draft is written via
 * <code>+[TTIOSpectralDataset writeMinimalToPath:...mixedRuns:...]</code>.
 *
 * @param path  Output <code>.tio</code> path.
 * @param error Out error on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)writeToPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error;

/** As <code>-writeToPath:error:</code>, reporting stream progress. */
- (BOOL)writeToPath:(NSString *)path
           progress:(nullable TTIOProgressBlock)progress
              error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif

/*
 * TTIOReader.h
 * TTI-O Objective-C Implementation
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#ifndef TTIO_READER_H
#define TTIO_READER_H

#import <Foundation/Foundation.h>
#import "Core/TTIOProgressSink.h"

@class TTIOImportedDataset;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Declared In:</em> Import/TTIOReader.h</p>
 *
 * <p>Uniform importer interface: parse one or more sources into a
 * normalized <code>TTIOImportedDataset</code> draft. Per-format
 * adapters (OT5/OT6) implement this protocol and the importer
 * registry (OT7) dispatches through it.</p>
 *
 * <p><code>inputs[0]</code> is the primary source; extra entries carry
 * secondary files (e.g. an imzML <code>.ibd</code>). <code>options</code>
 * carries format-specific knobs (name, sample, region, reference, ms2,
 * ibd, encoding).</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.Reader</code><br/>
 * Java: <code>global.thalion.ttio.importers.Reader</code></p>
 */
@protocol TTIOReader <NSObject>

/**
 * Parses <code>inputs</code> into a <code>TTIOImportedDataset</code> draft.
 *
 * @param inputs   Source paths; <code>inputs[0]</code> is the primary source.
 * @param options  Format-specific knobs.
 * @param progress Optional progress callback.
 * @param error    Out error on failure.
 * @return The imported-dataset draft, or <code>nil</code> on failure.
 */
- (nullable TTIOImportedDataset *)readInputs:(NSArray<NSString *> *)inputs
                                     options:(NSDictionary<NSString *, id> *)options
                                    progress:(nullable TTIOProgressBlock)progress
                                       error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif

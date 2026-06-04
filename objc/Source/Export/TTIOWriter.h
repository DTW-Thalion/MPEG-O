/*
 * TTIOWriter.h
 * TTI-O Objective-C Implementation
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#ifndef TTIO_WRITER_H
#define TTIO_WRITER_H

#import <Foundation/Foundation.h>

@class TTIOSpectralDataset;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Declared In:</em> Export/TTIOWriter.h</p>
 *
 * <p>Uniform exporter interface: serialize one layer of an opened
 * dataset to an output path. Per-format adapters (OT5/OT6) implement
 * this protocol and the exporter registry (OT7) dispatches through it.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.Writer</code><br/>
 * Java: <code>global.thalion.ttio.exporters.Writer</code></p>
 */
@protocol TTIOWriter <NSObject>

/**
 * Serializes one <code>layer</code> of <code>dataset</code> to
 * <code>output</code>.
 *
 * @param dataset The opened dataset to export.
 * @param layer   Optional layer/run selector; <code>nil</code> for the default.
 * @param output  Destination path.
 * @param options Format-specific knobs.
 * @param error   Out error on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)writeDataset:(TTIOSpectralDataset *)dataset
               layer:(nullable NSString *)layer
            toOutput:(NSString *)output
             options:(NSDictionary<NSString *, id> *)options
               error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif

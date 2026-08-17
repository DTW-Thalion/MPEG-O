/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_SPECTRAL_STREAM_SOURCE_H
#define TTIO_SPECTRAL_STREAM_SOURCE_H

#import <Foundation/Foundation.h>
#import "Core/TTIOProgressSink.h"
#import "Providers/TTIOStorageProtocols.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOWrittenSpectralBatch;
@class TTIOInstrumentConfig;
@class TTIOChromatogram;

NS_ASSUME_NONNULL_BEGIN

/** Hands each batch to <code>emit</code> in order; returns NO with
 *  <code>error</code> when the source fails, and stops as soon as
 *  <code>emit</code> returns NO. */
typedef BOOL (^TTIOSpectralBatchProducer)(BOOL (^emit)(TTIOWrittenSpectralBatch *batch, NSError **error),
                                          NSError **error);

/** A spectral run delivered as a sequence of batches, written through
 *  TTIOSpectralStreamWriter when the importing dataset is written.
 *  Python: <code>SpectralStreamSource</code>; Java:
 *  <code>SpectralStreamSource</code>. */
@interface TTIOSpectralStreamSource : NSObject

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) TTIOSpectralBatchProducer batches;
@property (nonatomic, readonly) TTIOAcquisitionMode acquisitionMode;
@property (nonatomic, readonly, strong, nullable) TTIOInstrumentConfig *instrumentConfig;
@property (nonatomic, readonly) NSUInteger batchSpectra;
/** Chromatograms known only once the batches are exhausted; nil for none. */
@property (nonatomic, readonly, copy, nullable) NSArray<TTIOChromatogram *> * _Nullable (^chromatogramsAfter)(void);

- (instancetype)initWithName:(NSString *)name
                     batches:(TTIOSpectralBatchProducer)batches
             acquisitionMode:(TTIOAcquisitionMode)mode
            instrumentConfig:(nullable TTIOInstrumentConfig *)config
                batchSpectra:(NSUInteger)batchSpectra
          chromatogramsAfter:(nullable NSArray<TTIOChromatogram *> * _Nullable (^)(void))chromatogramsAfter;

/** Run every batch through a TTIOSpectralStreamWriter on
 *  <code>study</code>; returns the spectra written, or NSNotFound with
 *  <code>error</code>. */
- (NSUInteger)writeIntoStudy:(id<TTIOStorageGroup>)study
                    progress:(nullable TTIOProgressBlock)progress
                       error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif

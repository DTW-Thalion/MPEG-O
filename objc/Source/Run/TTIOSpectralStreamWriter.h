/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_SPECTRAL_STREAM_WRITER_H
#define TTIO_SPECTRAL_STREAM_WRITER_H

#import <Foundation/Foundation.h>
#import "Providers/TTIOStorageProtocols.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOSpectrum;
@class TTIOWrittenSpectralBatch;
@class TTIOInstrumentConfig;
@class TTIOChromatogram;
@class TTIOProvenanceRecord;

NS_ASSUME_NONNULL_BEGIN

/** Run-level options of a streamed spectral run. Python:
 *  <code>SpectralStreamWriter</code> keyword arguments; Java:
 *  <code>SpectralStreamWriter.Options</code>. */
@interface TTIOSpectralStreamWriterOptions : NSObject <NSCopying>
/** Persisted spectrum class, e.g. <code>TTIOMassSpectrum</code>. */
@property (nonatomic, copy) NSString *spectrumClass;
@property (nonatomic) TTIOAcquisitionMode acquisitionMode;
@property (nonatomic, copy) NSArray<NSString *> *channelNames;
@property (nonatomic, strong, nullable) TTIOInstrumentConfig *instrumentConfig;
/** Spectra buffered per <code>appendSpectrum:</code> flush; default 4096. */
@property (nonatomic) NSUInteger batchSpectra;
@property (nonatomic) BOOL optDisableFloatDelta;
@property (nonatomic) TTIOCompression signalCompression;
@property (nonatomic, copy, nullable) NSString *nucleusType;
@property (nonatomic, copy, nullable) NSString *solvent;
@property (nonatomic, copy) NSArray<TTIOProvenanceRecord *> *provenanceRecords;
/** Worker threads for codec-17 block encode (0 = TTIO_THREADS, else cores
 *  minus 8; 1 = the serial path). Blocks are appended in emission order by
 *  the caller's thread; the file is byte for byte the one thread's. */
@property (nonatomic) NSUInteger threads;

/** Mass-spectrometry defaults: zlib (which resolves to codec 17 on
 *  <code>TTIOMassSpectrum</code> runs unless disabled), 4096 per batch. */
+ (instancetype)msOptionsWithMode:(TTIOAcquisitionMode)mode
                     channelNames:(NSArray<NSString *> *)channelNames
                 instrumentConfig:(nullable TTIOInstrumentConfig *)config;
@end

/** Writes one spectral run in the same layout as
 *  <code>-[TTIOAcquisitionRun writeToGroup:name:error:]</code>, but from
 *  batches: the spectrum_index columns and the channel datasets are
 *  extendable and grow per batch; codec-17 channels are emitted a block
 *  at a time with the header rewritten at close. Python:
 *  <code>ttio.SpectralStreamWriter</code>; Java:
 *  <code>SpectralStreamWriter</code>. */
@interface TTIOSpectralStreamWriter : NSObject

- (instancetype)initWithStudyGroup:(id<TTIOStorageGroup>)study
                           runName:(NSString *)runName
                           options:(TTIOSpectralStreamWriterOptions *)options;

/** Spectra written plus those still buffered. */
@property (nonatomic, readonly) NSUInteger spectrumCount;
@property (nonatomic, readonly) NSUInteger threads;

/** Chromatograms written at close. */
- (void)setChromatograms:(nullable NSArray<TTIOChromatogram *> *)chromatograms;

/** Buffer one spectrum; a full buffer flushes. */
- (BOOL)appendSpectrum:(TTIOSpectrum *)spectrum error:(NSError **)error;
/** Flush the buffer, then write the batch. */
- (BOOL)appendBatch:(TTIOWrittenSpectralBatch *)batch error:(NSError **)error;
/** Write the buffered spectra as one batch. */
- (BOOL)flush:(NSError **)error;
/** Flush, finalise the codec-17 headers, counts, chromatograms and
 *  provenance. Idempotent. */
- (BOOL)close:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif

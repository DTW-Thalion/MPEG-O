/*
 * TTIOWrittenRun — flat-buffer value object for
 * +[TTIOSpectralDataset writeMinimalToPath:...].
 *
 * Mirrors the Python `ttio.spectral_dataset.WrittenRun` dataclass.
 * The high-level TTIOAcquisitionRun / TTIOMassSpectrum API requires
 * one NSData per spectrum per channel; at write time the writer
 * iterates every spectrum and memcpy-concatenates the per-spectrum
 * buffers into a flat channel. Callers with already-flat arrays can
 * skip both costs by building an TTIOWrittenRun and calling
 * +writeMinimalToPath: on TTIOSpectralDataset.
 *
 * All buffer fields must be little-endian and typed as documented
 * below. No validation beyond length; the writer trusts the caller.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef TTIO_WRITTEN_RUN_H
#define TTIO_WRITTEN_RUN_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"

@class TTIOProvenanceRecord;

NS_ASSUME_NONNULL_BEGIN

@interface TTIOWrittenRun : NSObject

/** "TTIOMassSpectrum" or "TTIONMRSpectrum". */
@property (nonatomic, copy, readonly) NSString *spectrumClassName;

/** AcquisitionMode raw int; see TTIOAcquisitionMode. */
@property (nonatomic, readonly) int64_t acquisitionMode;

/** Flat per-channel signal buffers, keyed by channel name. Each value
 *  is an NSData of float64 little-endian, already concatenated across
 *  spectra in index order. */
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSData *> *channelData;

// All index arrays are parallel with length = spectrumCount.
@property (nonatomic, copy, readonly) NSData *offsets;               // int64 LE
@property (nonatomic, copy, readonly) NSData *lengths;               // uint32 LE
@property (nonatomic, copy, readonly) NSData *retentionTimes;        // float64 LE
@property (nonatomic, copy, readonly) NSData *msLevels;              // int32 LE
@property (nonatomic, copy, readonly) NSData *polarities;            // int32 LE
@property (nonatomic, copy, readonly) NSData *precursorMzs;          // float64 LE
@property (nonatomic, copy, readonly) NSData *precursorCharges;      // int32 LE
@property (nonatomic, copy, readonly) NSData *basePeakIntensities;   // float64 LE

/** Optional — NMR runs set this; MS runs leave empty. */
@property (nonatomic, copy) NSString *nucleusType;

/** v0.3 M21. "gzip", "none", "lz4", or "numpress_delta". Defaults to "gzip". */
@property (nonatomic, copy) NSString *signalCompression;

/** Per-run provenance records. Persisted under the run's group as
 *  ``provenance/steps`` (compound dataset) plus a legacy
 *  ``@provenance_json`` attribute mirror — matches the layout that
 *  ``-[TTIOAcquisitionRun writeToGroup:name:error:]`` emits, and
 *  the cross-language wire format Python's ``WrittenRun.provenance_records``
 *  / Java's ``WrittenRun.provenanceRecords`` write to. Defaults to
 *  ``@[]`` so callers that don't ship per-run provenance get
 *  byte-parity with pre-v0.6 files. */
@property (nonatomic, copy) NSArray<TTIOProvenanceRecord *> *provenanceRecords;

/** v1.10 #10 (offsets-cumsum) opt-out for MS spectrum_index +
 *  chromatogram_index. Default NO — new files omit the redundant
 *  ``offsets`` column (computed from ``cumsum(lengths)`` on read).
 *  Set to YES to keep the column on disk for byte-equivalent
 *  backward compat with pre-v1.10 readers. */
@property (nonatomic, assign) BOOL optKeepOffsetsColumns;

- (instancetype)initWithSpectrumClassName:(NSString *)spectrumClassName
                          acquisitionMode:(int64_t)acquisitionMode
                              channelData:(NSDictionary<NSString *, NSData *> *)channelData
                                  offsets:(NSData *)offsets
                                  lengths:(NSData *)lengths
                           retentionTimes:(NSData *)retentionTimes
                                 msLevels:(NSData *)msLevels
                               polarities:(NSData *)polarities
                             precursorMzs:(NSData *)precursorMzs
                         precursorCharges:(NSData *)precursorCharges
                      basePeakIntensities:(NSData *)basePeakIntensities;

@end

NS_ASSUME_NONNULL_END

#endif

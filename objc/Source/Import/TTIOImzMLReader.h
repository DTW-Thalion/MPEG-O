/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_IMZML_READER_H
#define TTIO_IMZML_READER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * One pixel's worth of parsed imzML data: spatial coordinates plus the
 * mass-spectrometry intensity / m/z arrays that came out of the .ibd
 * binary at the offsets named in the .imzML XML.
 *
 * In continuous mode every pixel's `mzArray` aliases the same shared
 * NSData (allocated once for the run) — the v0.9 Python reference
 * implementation makes the same guarantee.
 */
@interface TTIOImzMLPixelSpectrum : NSObject

@property (nonatomic, readonly) NSInteger x;
@property (nonatomic, readonly) NSInteger y;
@property (nonatomic, readonly) NSInteger z;
/** Little-endian float64 buffer, length = mzCount * 8. */
@property (nonatomic, readonly, strong) NSData *mzArray;
/** Little-endian float64 buffer, length = mzCount * 8. */
@property (nonatomic, readonly, strong) NSData *intensityArray;
@property (nonatomic, readonly) NSUInteger mzCount;

/**
 * v0.9+: public initializer for callers that construct pixel spectra
 * from in-memory buffers (e.g. TTIOImzMLWriter, tests). The importer
 * itself uses a private init; this one accepts equal-length float64
 * mz + intensity NSData buffers and derives mzCount.
 *
 * Returns nil + error when mzArray / intensityArray aren't both
 * non-zero multiples of 8 bytes, or when their element counts differ.
 */
- (nullable instancetype)initWithX:(NSInteger)x
                                  y:(NSInteger)y
                                  z:(NSInteger)z
                            mzArray:(NSData *)mzArray
                     intensityArray:(NSData *)intensityArray
                              error:(NSError * _Nullable * _Nullable)error;

@end

/**
 * Result of parsing an imzML + .ibd pair. Pure value object; the
 * importer does no I/O beyond construction.
 */
@interface TTIOImzMLImport : NSObject

/** "continuous" or "processed". */
@property (nonatomic, readonly, copy) NSString *mode;
/** 32-character lowercase hex (no dashes, no braces). */
@property (nonatomic, readonly, copy) NSString *uuidHex;
@property (nonatomic, readonly) NSInteger gridMaxX;
@property (nonatomic, readonly) NSInteger gridMaxY;
@property (nonatomic, readonly) NSInteger gridMaxZ;
@property (nonatomic, readonly) double pixelSizeX;
@property (nonatomic, readonly) double pixelSizeY;
@property (nonatomic, readonly, copy) NSString *scanPattern;
@property (nonatomic, readonly, copy) NSArray<TTIOImzMLPixelSpectrum *> *spectra;
@property (nonatomic, readonly, copy) NSString *sourceImzML;
@property (nonatomic, readonly, copy) NSString *sourceIbd;

@end

/**
 * imzML + .ibd importer — v0.9 M59.
 *
 * imzML is the dominant interchange format for mass-spectrometry
 * imaging. Two files:
 *
 *   - `<stem>.imzML` — XML metadata mirroring mzML, with each
 *     `<spectrum>` carrying an external offset / external array
 *     length / external encoded length cvParam triple.
 *   - `<stem>.ibd`   — concatenated binary mass / intensity arrays
 *     prefixed by a 16-byte UUID that must match the
 *     `IMS:1000042 universally unique identifier` cvParam in the
 *     metadata (HANDOFF gotcha 49).
 *
 * Modes:
 *   - "continuous" (`IMS:1000030`) — single shared m/z array stored
 *     once; per-pixel intensity arrays follow.
 *   - "processed"  (`IMS:1000031`) — per-pixel m/z + intensity.
 *
 * On malformed input the reader returns nil and populates `error`
 * with a descriptive `NSError` in `TTIOImzMLReaderErrorDomain`.
 *
 * Cross-language equivalents:
 *   Python: ttio.importers.imzml
 *   Java:   com.dtwthalion.ttio.importers.ImzMLReader
 */
@interface TTIOImzMLReader : NSObject

/** Read an imzML + .ibd pair. If `ibdPath` is nil, the sibling
 *  `<stem>.ibd` is used. */
+ (nullable TTIOImzMLImport *)readFromImzMLPath:(NSString *)imzmlPath
                                         ibdPath:(nullable NSString *)ibdPath
                                           error:(NSError **)error;

@end

extern NSString *const TTIOImzMLReaderErrorDomain;

typedef NS_ENUM(NSInteger, TTIOImzMLReaderErrorCode) {
    TTIOImzMLReaderErrorParseFailed         = 1,
    TTIOImzMLReaderErrorMissingMetadata     = 2,
    TTIOImzMLReaderErrorUUIDMismatch        = 3,
    TTIOImzMLReaderErrorOffsetOverflow      = 4,
    TTIOImzMLReaderErrorMissingFile         = 5,
    TTIOImzMLReaderErrorBinaryShorterThanUUID = 6
};

NS_ASSUME_NONNULL_END

#endif /* TTIO_IMZML_READER_H */

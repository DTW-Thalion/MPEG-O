/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef MPGO_IMZML_READER_H
#define MPGO_IMZML_READER_H

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
@interface MPGOImzMLPixelSpectrum : NSObject

@property (nonatomic, readonly) NSInteger x;
@property (nonatomic, readonly) NSInteger y;
@property (nonatomic, readonly) NSInteger z;
/** Little-endian float64 buffer, length = mzCount * 8. */
@property (nonatomic, readonly, strong) NSData *mzArray;
/** Little-endian float64 buffer, length = mzCount * 8. */
@property (nonatomic, readonly, strong) NSData *intensityArray;
@property (nonatomic, readonly) NSUInteger mzCount;

@end

/**
 * Result of parsing an imzML + .ibd pair. Pure value object; the
 * importer does no I/O beyond construction.
 */
@interface MPGOImzMLImport : NSObject

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
@property (nonatomic, readonly, copy) NSArray<MPGOImzMLPixelSpectrum *> *spectra;
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
 * with a descriptive `NSError` in `MPGOImzMLReaderErrorDomain`.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.importers.imzml
 *   Java:   com.dtwthalion.mpgo.importers.ImzMLReader
 */
@interface MPGOImzMLReader : NSObject

/** Read an imzML + .ibd pair. If `ibdPath` is nil, the sibling
 *  `<stem>.ibd` is used. */
+ (nullable MPGOImzMLImport *)readFromImzMLPath:(NSString *)imzmlPath
                                         ibdPath:(nullable NSString *)ibdPath
                                           error:(NSError **)error;

@end

extern NSString *const MPGOImzMLReaderErrorDomain;

typedef NS_ENUM(NSInteger, MPGOImzMLReaderErrorCode) {
    MPGOImzMLReaderErrorParseFailed         = 1,
    MPGOImzMLReaderErrorMissingMetadata     = 2,
    MPGOImzMLReaderErrorUUIDMismatch        = 3,
    MPGOImzMLReaderErrorOffsetOverflow      = 4,
    MPGOImzMLReaderErrorMissingFile         = 5,
    MPGOImzMLReaderErrorBinaryShorterThanUUID = 6
};

NS_ASSUME_NONNULL_END

#endif /* MPGO_IMZML_READER_H */

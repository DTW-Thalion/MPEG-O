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
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOImzMLReader.h</p>
 *
 * <p>One pixel's worth of parsed imzML data: spatial coordinates
 * plus the mass-spectrometry intensity / m/z arrays that came out of
 * the <code>.ibd</code> binary at the offsets named in the
 * <code>.imzML</code> XML.</p>
 *
 * <p>In continuous mode every pixel's <code>mzArray</code> aliases
 * the same shared <code>NSData</code> (allocated once for the run)
 * &#8212; the Python reference implementation makes the same
 * guarantee.</p>
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
 * Public initialiser for callers that construct pixel spectra from
 * in-memory buffers (for example <code>TTIOImzMLWriter</code> or
 * tests). The importer itself uses a private init; this one accepts
 * equal-length float64 mz + intensity <code>NSData</code> buffers and
 * derives <code>mzCount</code>.
 *
 * @param x              X coordinate of the pixel.
 * @param y              Y coordinate of the pixel.
 * @param z              Z coordinate of the pixel.
 * @param mzArray        Float64 m/z buffer.
 * @param intensityArray Float64 intensity buffer of equal length.
 * @param error          Out-parameter populated when array sizes are
 *                       invalid or unequal.
 * @return An initialised pixel spectrum, or <code>nil</code> on
 *         malformed input.
 */
- (nullable instancetype)initWithX:(NSInteger)x
                                  y:(NSInteger)y
                                  z:(NSInteger)z
                            mzArray:(NSData *)mzArray
                     intensityArray:(NSData *)intensityArray
                              error:(NSError * _Nullable * _Nullable)error;

@end

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOImzMLReader.h</p>
 *
 * <p>Result of parsing an imzML + .ibd pair. Pure value object; the
 * importer does no I/O beyond construction.</p>
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
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOImzMLReader.h</p>
 *
 * <p>imzML + .ibd importer. imzML is the dominant interchange format
 * for mass-spectrometry imaging. Two files:</p>
 *
 * <ul>
 *  <li><code>&lt;stem&gt;.imzML</code> &#8212; XML metadata
 *      mirroring mzML, with each <code>&lt;spectrum&gt;</code>
 *      carrying an external offset / external array length /
 *      external encoded length cvParam triple.</li>
 *  <li><code>&lt;stem&gt;.ibd</code> &#8212; concatenated binary
 *      mass / intensity arrays prefixed by a 16-byte UUID that must
 *      match the
 *      <code>IMS:1000042 universally unique identifier</code>
 *      cvParam in the metadata.</li>
 * </ul>
 *
 * <p><strong>Modes:</strong></p>
 * <ul>
 *  <li><code>"continuous"</code> (<code>IMS:1000030</code>) &#8212;
 *      single shared m/z array stored once; per-pixel intensity
 *      arrays follow.</li>
 *  <li><code>"processed"</code> (<code>IMS:1000031</code>) &#8212;
 *      per-pixel m/z + intensity.</li>
 * </ul>
 *
 * <p>On malformed input the reader returns <code>nil</code> and
 * populates <code>error</code> with a descriptive
 * <code>NSError</code> in
 * <code>TTIOImzMLReaderErrorDomain</code>.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers.imzml</code><br/>
 * Java: <code>global.thalion.ttio.importers.ImzMLReader</code></p>
 */
@interface TTIOImzMLReader : NSObject

/**
 * Reads an imzML + .ibd pair.
 *
 * @param imzmlPath Path to the <code>.imzML</code> XML metadata
 *                  file.
 * @param ibdPath   Path to the <code>.ibd</code> binary, or
 *                  <code>nil</code> to use the sibling
 *                  <code>&lt;stem&gt;.ibd</code>.
 * @param error     Out-parameter populated on failure.
 * @return A populated <code>TTIOImzMLImport</code>, or
 *         <code>nil</code> on failure.
 */
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

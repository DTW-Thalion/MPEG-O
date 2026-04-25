/*
 * TTIOImzMLWriter — imzML + .ibd exporter (v0.9+).
 *
 * Reverses TTIOImzMLReader: takes a list of pixel spectra + grid
 * metadata and emits the canonical paired .imzML / .ibd files.
 * Both continuous mode (shared m/z axis, per-pixel intensity arrays)
 * and processed mode (per-pixel m/z + intensity arrays) are
 * supported.
 *
 * The emitted XML uses the canonical IMS accessions (IMS:1000080 for
 * UUID, IMS:1000042/43 for max counts) that real-world imzML files
 * like the pyimzML test corpus use. Output passes pyimzml's
 * ImzMLParser and round-trips through TTIOImzMLReader bit-identically.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Cross-language equivalents
 * --------------------------
 * Python: ttio.exporters.imzml  ·
 * Java:   com.dtwthalion.tio.exporters.ImzMLWriter
 *
 * @since 0.9
 */
#import <Foundation/Foundation.h>

@class TTIOImzMLPixelSpectrum;
@class TTIOImzMLImport;

NS_ASSUME_NONNULL_BEGIN

@interface TTIOImzMLWriteResult : NSObject
@property (nonatomic, readonly, copy) NSString *imzmlPath;
@property (nonatomic, readonly, copy) NSString *ibdPath;
@property (nonatomic, readonly, copy) NSString *uuidHex;  /**< 32 lowercase hex */
@property (nonatomic, readonly, copy) NSString *mode;      /**< "continuous" / "processed" */
@property (nonatomic, readonly) NSUInteger nPixels;
@end


@interface TTIOImzMLWriter : NSObject

/**
 * Write an imzML + .ibd pair.
 *
 * @param pixels       Array of TTIOImzMLPixelSpectrum objects.
 * @param imzmlPath    Destination .imzML path; ibdPath is derived by
 *                      swapping the extension when nil.
 * @param ibdPath      Optional explicit .ibd path (nil => auto).
 * @param mode         "continuous" or "processed".
 * @param gridMaxX/Y/Z Pixel grid extents (0 => derive from pixel coords).
 * @param pixelSizeX/Y Pixel size in micrometres (0 => omit cvParam).
 * @param scanPattern  Free-text scan pattern ("flyback", etc.).
 * @param uuidHex      Optional explicit UUID; nil => random UUID4.
 * @param error        Populated on failure.
 */
+ (nullable TTIOImzMLWriteResult *)writePixels:(NSArray<TTIOImzMLPixelSpectrum *> *)pixels
                                     toImzMLPath:(NSString *)imzmlPath
                                         ibdPath:(nullable NSString *)ibdPath
                                            mode:(NSString *)mode
                                       gridMaxX:(NSInteger)gridMaxX
                                       gridMaxY:(NSInteger)gridMaxY
                                       gridMaxZ:(NSInteger)gridMaxZ
                                     pixelSizeX:(double)pixelSizeX
                                     pixelSizeY:(double)pixelSizeY
                                     scanPattern:(NSString *)scanPattern
                                        uuidHex:(nullable NSString *)uuidHex
                                          error:(NSError * _Nullable * _Nullable)error;

/** Round-trip helper: re-emit an TTIOImzMLImport to disk. */
+ (nullable TTIOImzMLWriteResult *)writeFromImport:(TTIOImzMLImport *)import
                                         toImzMLPath:(NSString *)imzmlPath
                                             ibdPath:(nullable NSString *)ibdPath
                                               error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END

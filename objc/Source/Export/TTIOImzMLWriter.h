/*
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>

@class TTIOImzMLPixelSpectrum;
@class TTIOImzMLImport;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIOImzMLWriter.h</p>
 *
 * <p>Pure value object describing a successful imzML + .ibd write:
 * output paths, UUID, mode, and pixel count.</p>
 */
@interface TTIOImzMLWriteResult : NSObject
@property (nonatomic, readonly, copy) NSString *imzmlPath;
@property (nonatomic, readonly, copy) NSString *ibdPath;
/** 32 lowercase hex characters. */
@property (nonatomic, readonly, copy) NSString *uuidHex;
/** <code>"continuous"</code> or <code>"processed"</code>. */
@property (nonatomic, readonly, copy) NSString *mode;
@property (nonatomic, readonly) NSUInteger nPixels;
@end


/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIOImzMLWriter.h</p>
 *
 * <p>imzML + .ibd exporter. Reverses
 * <code>TTIOImzMLReader</code>: takes a list of pixel spectra plus
 * grid metadata and emits the canonical paired .imzML / .ibd files.
 * Both continuous mode (shared m/z axis, per-pixel intensity arrays)
 * and processed mode (per-pixel m/z + intensity arrays) are
 * supported.</p>
 *
 * <p>The emitted XML uses the canonical IMS accessions
 * (<code>IMS:1000080</code> for UUID, <code>IMS:1000042/43</code> for
 * max counts) that real-world imzML files like the pyimzML test
 * corpus use. Output passes pyimzml's <code>ImzMLParser</code> and
 * round-trips through <code>TTIOImzMLReader</code>
 * bit-identically.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.imzml</code><br/>
 * Java: <code>global.thalion.ttio.exporters.ImzMLWriter</code></p>
 */
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

/**
 * Round-trip helper: re-emits a <code>TTIOImzMLImport</code> to
 * disk.
 *
 * @param import     Import value object previously produced by the
 *                   reader.
 * @param imzmlPath  Destination .imzML path.
 * @param ibdPath    Optional explicit .ibd path; <code>nil</code>
 *                   derives by extension swap.
 * @param error      Out-parameter populated on failure.
 * @return Write result on success, or <code>nil</code> on failure.
 */
+ (nullable TTIOImzMLWriteResult *)writeFromImport:(TTIOImzMLImport *)import
                                         toImzMLPath:(NSString *)imzmlPath
                                             ibdPath:(nullable NSString *)ibdPath
                                               error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END

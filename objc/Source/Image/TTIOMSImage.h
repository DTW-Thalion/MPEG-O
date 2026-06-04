#ifndef TTIO_MS_IMAGE_H
#define TTIO_MS_IMAGE_H

#import <Foundation/Foundation.h>
#import "Image/TTIOImage.h"

@class TTIOHDF5Group;
@class TTIOPixelSpectrum;

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Image/TTIOMSImage.h</p>
 *
 * <p>Mass-spectrometry imaging dataset: a
 * <code>width &#215; height</code> grid of pixels, each pixel a
 * spectral profile of <code>spectralPoints</code> float64 values.
 * Carries dataset-level fields (title, identifications,
 * quantifications, provenance) directly — composition over
 * <code>TTIOSpectralDataset</code>, mirroring the Java and Python
 * equivalents.</p>
 *
 * <p>The image cube is persisted under
 * <code>/study/image_cube/</code> as a 3-D HDF5 dataset with
 * tile-aligned chunking. Buffer layout is row-major:
 * <code>cube[(y * width + x) * spectralPoints + s]</code>.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.ms_image.MSImage</code><br/>
 * Java: <code>global.thalion.ttio.MSImage</code></p>
 */
@interface TTIOMSImage : TTIOImage

#pragma mark - Image-specific fields

/** Length-spectralPoints float64 array; nil for legacy files. */
@property (readonly, copy, nullable) NSData *mzAxis;

#pragma mark - Initialisation

/**
 * Convenience initialiser for image-only datasets.
 * Dataset-level fields default to empty / nil.
 */
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube;

/**
 * Designated initialiser combining image fields with full dataset
 * metadata.
 */
- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                        width:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                   pixelSizeX:(double)pixelSizeX
                   pixelSizeY:(double)pixelSizeY
                  scanPattern:(NSString *)scanPattern
                         cube:(NSData *)cube;

/**
 * Designated initialiser including mzAxis (1.2.0+).
 */
- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                        width:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                   pixelSizeX:(double)pixelSizeX
                   pixelSizeY:(double)pixelSizeY
                  scanPattern:(NSString *)scanPattern
                         cube:(NSData *)cube
                       mzAxis:(nullable NSData *)mzAxis;

/** Project this image as a continuous-mode pixel list. Raises
 *  NSInternalInconsistencyException when mzAxis is nil/empty. */
- (NSArray<TTIOPixelSpectrum *> *)pixelSpectra;

#pragma mark - Persistence

/**
 * Reads an MS image from <code>path</code>. Auto-detects the
 * canonical <code>/study/image_cube/</code> layout and falls back
 * to the legacy root <code>/image_cube/</code> path when the
 * canonical group is absent.
 */
+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error;

/**
 * Writes this image to <code>path</code>. Creates the full
 * dataset-level HDF5 structure under <code>/study/</code> and the
 * <code>image_cube</code> group within it.
 */
- (BOOL)writeToFilePath:(NSString *)path error:(NSError **)error;

/**
 * Reads a <code>tileWidth</code> x <code>tileHeight</code> tile
 * starting at <code>(x, y)</code>. Supports both the canonical
 * and legacy cube paths.
 */
+ (NSData *)readTileFromFilePath:(NSString *)path
                             atX:(NSUInteger)x
                               y:(NSUInteger)y
                           width:(NSUInteger)tileWidth
                          height:(NSUInteger)tileHeight
                           error:(NSError **)error;

@end

#endif

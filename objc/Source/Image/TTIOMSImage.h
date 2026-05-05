#ifndef TTIO_MS_IMAGE_H
#define TTIO_MS_IMAGE_H

#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"

@class TTIOHDF5Group;

/**
 * <heading>TTIOMSImage</heading>
 *
 * <p><em>Inherits From:</em> TTIOSpectralDataset : NSObject</p>
 * <p><em>Conforms To:</em> TTIOEncryptable (inherited)</p>
 * <p><em>Declared In:</em> Image/TTIOMSImage.h</p>
 *
 * <p>Mass-spectrometry imaging dataset: a
 * <code>width &times; height</code> grid of pixels, each pixel a
 * spectral profile of <code>spectralPoints</code> float64 values.
 * Inherits from <code>TTIOSpectralDataset</code> so it carries
 * identifications, quantifications, provenance records, and the
 * <code>TTIOEncryptable</code> / <code>-closeFile</code>
 * semantics for free.</p>
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
@interface TTIOMSImage : TTIOSpectralDataset

/** Image width in pixels. */
@property (readonly) NSUInteger width;

/** Image height in pixels. */
@property (readonly) NSUInteger height;

/** Spectral points per pixel. */
@property (readonly) NSUInteger spectralPoints;

/** Tile size in pixels for chunked storage. */
@property (readonly) NSUInteger tileSize;

/** Float64 row-major image cube. */
@property (readonly, copy) NSData *cube;

/** Pixel size in the X dimension (units instrument-specific);
 *  <code>0</code> when unknown. */
@property (readonly) double pixelSizeX;

/** Pixel size in the Y dimension; <code>0</code> when unknown. */
@property (readonly) double pixelSizeY;

/** Scan pattern identifier (e.g. <code>@"raster"</code>); empty
 *  when unknown. */
@property (readonly, copy) NSString *scanPattern;

#pragma mark - Initialisation

/**
 * Convenience initialiser for image-only datasets. Inherited
 * dataset fields default to empty / nil.
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

#pragma mark - Persistence

/**
 * Reads an MS image from <code>path</code>. Auto-detects the
 * canonical <code>/study/image_cube/</code> layout and falls back
 * to the legacy root <code>/image_cube/</code> path when the
 * canonical group is absent.
 */
+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error;

/**
 * Reads a <code>tileWidth &times; tileHeight</code> tile starting
 * at <code>(x, y)</code>. Supports both the canonical and legacy
 * cube paths.
 */
+ (NSData *)readTileFromFilePath:(NSString *)path
                             atX:(NSUInteger)x
                               y:(NSUInteger)y
                           width:(NSUInteger)tileWidth
                          height:(NSUInteger)tileHeight
                           error:(NSError **)error;

@end

#endif

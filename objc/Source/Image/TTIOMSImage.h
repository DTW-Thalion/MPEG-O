#ifndef TTIO_MS_IMAGE_H
#define TTIO_MS_IMAGE_H

#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"

@class TTIOHDF5Group;

/**
 * Mass-spectrometry imaging dataset: a width x height grid of pixels,
 * each pixel a spectral profile of `spectralPoints` float64 values.
 *
 * As of v0.2 (Milestone 12), TTIOMSImage inherits from
 * TTIOSpectralDataset, so it carries identifications, quantifications,
 * provenance records, and TTIOEncryptable / closeFile semantics for
 * free. The image cube itself is persisted under `/study/image_cube/`
 * as a 3-D HDF5 dataset with tile-aligned chunking.
 *
 * v0.1 layout (cube at `/image_cube/` in the root group) remains
 * readable as a fallback via +readFromFilePath:.
 *
 * Buffer layout (row-major): `cube[(y * width + x) * spectralPoints + s]`.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.ms_image.MSImage
 *   Java:   com.dtwthalion.tio.MSImage
 */
@interface TTIOMSImage : TTIOSpectralDataset

@property (readonly) NSUInteger width;
@property (readonly) NSUInteger height;
@property (readonly) NSUInteger spectralPoints;
@property (readonly) NSUInteger tileSize;
@property (readonly, copy) NSData *cube;     // float64[height * width * spectralPoints]

/** Spatial metadata — optional, zero/empty when unknown. */
@property (readonly) double pixelSizeX;
@property (readonly) double pixelSizeY;
@property (readonly, copy) NSString *scanPattern;

#pragma mark - Initialization

/** Convenience initializer for image-only datasets. Inherited dataset
 *  fields are set to empty / nil defaults. */
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube;

/** Full designated initializer — image fields plus dataset metadata. */
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

/** Override of TTIOSpectralDataset's read; falls back to v0.1
 *  `/image_cube/` if `/study/image_cube` is missing. */
+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error;

/**
 * Read a `tileWidth x tileHeight` tile starting at `(x, y)`. Supports
 * both the v0.2 /study/image_cube layout and the v0.1 /image_cube
 * layout by auto-detecting.
 */
+ (NSData *)readTileFromFilePath:(NSString *)path
                             atX:(NSUInteger)x
                               y:(NSUInteger)y
                           width:(NSUInteger)tileWidth
                          height:(NSUInteger)tileHeight
                           error:(NSError **)error;

@end

#endif

#ifndef MPGO_MS_IMAGE_H
#define MPGO_MS_IMAGE_H

#import <Foundation/Foundation.h>

/**
 * Mass-spectrometry imaging dataset: a `width × height` grid of pixels,
 * each pixel a spectral profile of `spectralPoints` float64 values.
 * Persisted as a 3-D HDF5 dataset with shape `[height, width, spectralPoints]`
 * and tile-aligned chunking so reading a `(tileX, tileY)` tile only
 * touches that tile's chunk on disk.
 *
 * The cube buffer is stored row-major: index = (y * width + x) * spectralPoints + s.
 *
 * For v0.1 MSImage is a standalone container — it is conceptually an
 * extension of MPGOSpectralDataset but does not yet inherit from it.
 * The same file may also embed a full MPGOSpectralDataset under /study/
 * via that class's writer; MSImage stores its cube under /image_cube/.
 */
@interface MPGOMSImage : NSObject

@property (readonly) NSUInteger width;
@property (readonly) NSUInteger height;
@property (readonly) NSUInteger spectralPoints;
@property (readonly) NSUInteger tileSize;
@property (readonly, copy) NSData *cube;     // float64[height * width * spectralPoints]

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube;

- (BOOL)writeToFilePath:(NSString *)path error:(NSError **)error;
+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error;

/**
 * Read a `tileWidth × tileHeight` tile starting at `(x, y)`. Returns
 * `tileHeight * tileWidth * spectralPoints` float64 doubles in row-major
 * layout. Issues a single 3-D hyperslab read against the on-disk dataset;
 * with chunking aligned to the tile size this reads exactly one chunk.
 */
+ (NSData *)readTileFromFilePath:(NSString *)path
                            atX:(NSUInteger)x
                              y:(NSUInteger)y
                          width:(NSUInteger)tileWidth
                         height:(NSUInteger)tileHeight
                          error:(NSError **)error;

@end

#endif

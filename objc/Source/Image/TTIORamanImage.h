#ifndef TTIO_RAMAN_IMAGE_H
#define TTIO_RAMAN_IMAGE_H

#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"

@class TTIOHDF5Group;

/**
 * Raman imaging / mapping dataset: a width x height grid of pixels,
 * each pixel a spectral profile of `spectralPoints` float64 values
 * indexed by a shared 1-D `wavenumbers` array (cm^-1).
 *
 * Mirrors TTIOMSImage's composition over TTIOSpectralDataset. The
 * cube is persisted under `/study/raman_image_cube/` with tile-aligned
 * chunking for efficient hyperslab reads.
 *
 * Buffer layout (row-major): `cube[(y * width + x) * spectralPoints + s]`.
 *
 * Cross-language equivalents:
 *   Python: ttio.raman_image.RamanImage
 *   Java:   global.thalion.ttio.RamanImage
 */
@interface TTIORamanImage : TTIOSpectralDataset

@property (readonly) NSUInteger width;
@property (readonly) NSUInteger height;
@property (readonly) NSUInteger spectralPoints;
@property (readonly) NSUInteger tileSize;
@property (readonly, copy) NSData *cube;         // float64[height * width * spectralPoints]
@property (readonly, copy) NSData *wavenumbers;  // float64[spectralPoints]

@property (readonly) double pixelSizeX;
@property (readonly) double pixelSizeY;
@property (readonly, copy) NSString *scanPattern;

@property (readonly) double excitationWavelengthNm;
@property (readonly) double laserPowerMw;

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers
       excitationWavelengthNm:(double)excitationNm
                 laserPowerMw:(double)laserPowerMw;

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
       excitationWavelengthNm:(double)excitationNm
                 laserPowerMw:(double)laserPowerMw
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers;

@end

#endif

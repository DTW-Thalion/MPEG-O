#ifndef TTIO_RAMAN_IMAGE_H
#define TTIO_RAMAN_IMAGE_H

#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"

@class TTIOHDF5Group;

/**
 * <p><em>Inherits From:</em> TTIOSpectralDataset : NSObject</p>
 * <p><em>Conforms To:</em> TTIOEncryptable (inherited)</p>
 * <p><em>Declared In:</em> Image/TTIORamanImage.h</p>
 *
 * <p>Raman imaging / mapping dataset: a
 * <code>width &#215; height</code> grid of pixels, each pixel a
 * spectral profile of <code>spectralPoints</code> float64 values
 * indexed by a shared 1-D <code>wavenumbers</code> array
 * (cm<sup>-1</sup>). Mirrors <code>TTIOMSImage</code>'s composition
 * over <code>TTIOSpectralDataset</code>.</p>
 *
 * <p>The cube is persisted under
 * <code>/study/raman_image_cube/</code> with tile-aligned chunking.
 * Buffer layout is row-major:
 * <code>cube[(y * width + x) * spectralPoints + s]</code>.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.raman_image.RamanImage</code><br/>
 * Java: <code>global.thalion.ttio.RamanImage</code></p>
 */
@interface TTIORamanImage : TTIOSpectralDataset

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

/** Float64 wavenumbers (cm<sup>-1</sup>) shared across all pixels. */
@property (readonly, copy) NSData *wavenumbers;

/** Pixel size in the X dimension; <code>0</code> when unknown. */
@property (readonly) double pixelSizeX;

/** Pixel size in the Y dimension; <code>0</code> when unknown. */
@property (readonly) double pixelSizeY;

/** Scan pattern identifier; empty when unknown. */
@property (readonly, copy) NSString *scanPattern;

/** Excitation laser wavelength in nm. */
@property (readonly) double excitationWavelengthNm;

/** Laser power in milliwatts. */
@property (readonly) double laserPowerMw;

/**
 * Convenience initialiser for image-only datasets.
 */
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers
       excitationWavelengthNm:(double)excitationNm
                 laserPowerMw:(double)laserPowerMw;

/**
 * Designated initialiser.
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
       excitationWavelengthNm:(double)excitationNm
                 laserPowerMw:(double)laserPowerMw
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers;

@end

#endif

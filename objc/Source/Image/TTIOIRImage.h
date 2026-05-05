#ifndef TTIO_IR_IMAGE_H
#define TTIO_IR_IMAGE_H

#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOHDF5Group;

/**
 * <p><em>Inherits From:</em> TTIOSpectralDataset : NSObject</p>
 * <p><em>Conforms To:</em> TTIOEncryptable (inherited)</p>
 * <p><em>Declared In:</em> Image/TTIOIRImage.h</p>
 *
 * <p>Mid-IR (FTIR microscopy) imaging dataset: a
 * <code>width &#215; height</code> grid of pixels, each pixel a
 * spectral profile of <code>spectralPoints</code> float64 values
 * indexed by a shared 1-D <code>wavenumbers</code> array
 * (cm<sup>-1</sup>). The cube values are either transmittance or
 * absorbance per <code>mode</code>.</p>
 *
 * <p>Persisted under <code>/study/ir_image_cube/</code>.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.ir_image.IRImage</code><br/>
 * Java: <code>global.thalion.ttio.IRImage</code></p>
 */
@interface TTIOIRImage : TTIOSpectralDataset

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

/** Float64 wavenumbers (cm<sup>-1</sup>) shared across pixels. */
@property (readonly, copy) NSData *wavenumbers;

/** Pixel size in the X dimension; <code>0</code> when unknown. */
@property (readonly) double pixelSizeX;

/** Pixel size in the Y dimension; <code>0</code> when unknown. */
@property (readonly) double pixelSizeY;

/** Scan pattern identifier; empty when unknown. */
@property (readonly, copy) NSString *scanPattern;

/** Whether <code>cube</code> holds transmittance or absorbance. */
@property (readonly) TTIOIRMode mode;

/** Spectral resolution in cm<sup>-1</sup>. */
@property (readonly) double resolutionCmInv;

/**
 * Convenience initialiser for image-only datasets.
 */
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers
                         mode:(TTIOIRMode)mode
              resolutionCmInv:(double)resolutionCmInv;

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
                         mode:(TTIOIRMode)mode
              resolutionCmInv:(double)resolutionCmInv
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers;

@end

#endif

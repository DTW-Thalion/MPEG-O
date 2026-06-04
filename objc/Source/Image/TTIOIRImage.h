#ifndef TTIO_IR_IMAGE_H
#define TTIO_IR_IMAGE_H

#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"
#import "Image/TTIOImage.h"

@class TTIOHDF5Group;

/**
 * <p><em>Inherits From:</em> NSObject</p>
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
@interface TTIOIRImage : TTIOImage

#pragma mark - Image-specific fields

/** Float64 wavenumbers (cm<sup>-1</sup>) shared across pixels. */
@property (readonly, copy) NSData *wavenumbers;

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

#pragma mark - Persistence

/**
 * Reads an IR image from <code>path</code>.
 */
+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error;

/**
 * Writes this image to <code>path</code>.
 */
- (BOOL)writeToFilePath:(NSString *)path error:(NSError **)error;

@end

#endif

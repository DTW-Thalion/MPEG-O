#ifndef TTIO_IR_IMAGE_H
#define TTIO_IR_IMAGE_H

#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOHDF5Group;

/**
 * Mid-IR (FTIR microscopy) imaging dataset: a width x height grid of
 * pixels, each pixel a spectral profile of `spectralPoints` float64
 * values indexed by a shared 1-D `wavenumbers` array (cm^-1). The
 * cube values are either transmittance or absorbance per `mode`.
 *
 * Persisted under `/study/ir_image_cube/`.
 *
 * Cross-language equivalents:
 *   Python: ttio.ir_image.IRImage
 *   Java:   com.dtwthalion.ttio.IRImage
 */
@interface TTIOIRImage : TTIOSpectralDataset

@property (readonly) NSUInteger width;
@property (readonly) NSUInteger height;
@property (readonly) NSUInteger spectralPoints;
@property (readonly) NSUInteger tileSize;
@property (readonly, copy) NSData *cube;
@property (readonly, copy) NSData *wavenumbers;

@property (readonly) double pixelSizeX;
@property (readonly) double pixelSizeY;
@property (readonly, copy) NSString *scanPattern;

@property (readonly) TTIOIRMode mode;
@property (readonly) double resolutionCmInv;

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers
                         mode:(TTIOIRMode)mode
              resolutionCmInv:(double)resolutionCmInv;

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

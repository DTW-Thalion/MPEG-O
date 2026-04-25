#ifndef TTIO_NMR_2D_SPECTRUM_H
#define TTIO_NMR_2D_SPECTRUM_H

#import "TTIOSpectrum.h"

@class TTIOAxisDescriptor;

/**
 * 2-D NMR spectrum (e.g. HSQC, COSY): a row-major float64 intensity
 * matrix of `width × height` points plus F1 and F2 axis descriptors.
 *
 * The matrix is stored on disk as a flattened 1-D dataset with the
 * shape recorded in scalar attributes; this is sufficient for round-trip
 * fidelity and keeps the HDF5 wrapper API surface small. A future
 * milestone may switch to a native 2-D dataset.
 */
@interface TTIONMR2DSpectrum : TTIOSpectrum

@property (readonly, copy)   NSData *intensityMatrix;     // float64, row-major
@property (readonly)         NSUInteger width;            // F2 points
@property (readonly)         NSUInteger height;           // F1 points
@property (readonly, strong) TTIOAxisDescriptor *f1Axis;
@property (readonly, strong) TTIOAxisDescriptor *f2Axis;
@property (readonly, copy)   NSString *nucleusF1;
@property (readonly, copy)   NSString *nucleusF2;

- (instancetype)initWithIntensityMatrix:(NSData *)matrix
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height
                                 f1Axis:(TTIOAxisDescriptor *)f1
                                 f2Axis:(TTIOAxisDescriptor *)f2
                              nucleusF1:(NSString *)nucleusF1
                              nucleusF2:(NSString *)nucleusF2
                          indexPosition:(NSUInteger)indexPosition
                                  error:(NSError **)error;

@end

/**
 * Cross-language equivalents:
 *   Java:   com.dtwthalion.ttio.NMR2DSpectrum
 *   Python: ttio.nmr_2d.NMR2DSpectrum
 */

#endif

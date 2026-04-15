#ifndef MPGO_NMR_2D_SPECTRUM_H
#define MPGO_NMR_2D_SPECTRUM_H

#import "MPGOSpectrum.h"

@class MPGOAxisDescriptor;

/**
 * 2-D NMR spectrum (e.g. HSQC, COSY): a row-major float64 intensity
 * matrix of `width × height` points plus F1 and F2 axis descriptors.
 *
 * The matrix is stored on disk as a flattened 1-D dataset with the
 * shape recorded in scalar attributes; this is sufficient for round-trip
 * fidelity and keeps the HDF5 wrapper API surface small. A future
 * milestone may switch to a native 2-D dataset.
 */
@interface MPGONMR2DSpectrum : MPGOSpectrum

@property (readonly, copy)   NSData *intensityMatrix;     // float64, row-major
@property (readonly)         NSUInteger width;            // F2 points
@property (readonly)         NSUInteger height;           // F1 points
@property (readonly, strong) MPGOAxisDescriptor *f1Axis;
@property (readonly, strong) MPGOAxisDescriptor *f2Axis;
@property (readonly, copy)   NSString *nucleusF1;
@property (readonly, copy)   NSString *nucleusF2;

- (instancetype)initWithIntensityMatrix:(NSData *)matrix
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height
                                 f1Axis:(MPGOAxisDescriptor *)f1
                                 f2Axis:(MPGOAxisDescriptor *)f2
                              nucleusF1:(NSString *)nucleusF1
                              nucleusF2:(NSString *)nucleusF2
                          indexPosition:(NSUInteger)indexPosition
                                  error:(NSError **)error;

@end

#endif
